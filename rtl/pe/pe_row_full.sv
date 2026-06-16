// =============================================================================
// pe_row_full.sv — 完整 PE Row(8-stage pipeline)
// =============================================================================
// 功能:
//   單一條 PE row 的完整資料路徑:每拍接收 16 對 A/B 運算元與 bitmask,
//   依序經 MFIU(交集 metadata)、distribution(運算元路由)、16 顆乘法器、
//   reduction tree(分段加總),最後累加至 local buffer;column 累加
//   完成後由 dump 介面讀出 C 值。另含 B 縱向 forwarding(b_vec_in 延 1 拍
//   轉發給下一條 row)。所有 dataflow 模式共用同一條物理 pipeline。
//
// Pipeline(PE_ROW_STAGES = 8):
//   S1     輸入打拍(A reg / B FIFO latch)
//   S2-S4  MFIU → effectual_idx / cut_after / out_addr(MFIU_STAGES = 3)
//   S5     A/B distribution(依 effectual_idx 路由運算元)
//   S6     Mul × 16(mac_unit)
//   S7     reduction tree(依 cut_after 分段加總)
//   S8     16→4 壓縮 + local buffer 寫入(RMW 完成另需 2 拍)
//
// 控制訊號對齊(本模組的核心職責):
//   MFIU 的 metadata 於 S4 產出、由不同 stage 消費,模組內以 delay line
//   對齊至各消費點:
//     effectual_idx → S5 直接使用
//     cut_after     → S7,延 DIST+MUL 拍
//     out_addr      → S8,延 DIST+MUL+TREE 拍
//     first_pass    → S8,自輸入端延 1+MFIU+DIST+MUL+TREE 拍對齊寫入時點
//   A/B 值於 S1 latch 後延 MFIU_STAGES 拍,與 metadata 同拍進入 S5。
//   各 stage 數定義於 trapezoid_pkg;上游模組 latency 改變時調整該處即可,
//   本模組結構不變。
//
// 介面(控制):
//   dataflow_sel [2]    dataflow 模式選擇
//   in_valid            此拍 a/b 輸入有效
//   cur_n        [9]    當前 output column(Dense IP:C 寫往 buffer[cur_n])
//   first_pass          該 column 第一段 K 時與 in_valid 同拍拉 1(buffer
//                       覆蓋寫入,等效清零);後續 K-tile 為 0(累加)
//   dump_en / dump_addr 讀出某 column 的 C 值。須於該 column 最後一筆
//                       in_valid 之後至少 PE_ROW_STAGES+1 拍才可發;
//                       c_valid / c_out 於 dump_en 後第 2 拍有效
//
// 介面(資料):
//   a_vec / a_bitmask         [16] A 運算元與 bitmask(row-stationary)
//   b_vec_in / b_bitmask_in   [16] B 運算元與 bitmask(自上一條 row)
//   b_vec_out / b_bitmask_out / b_valid_out  B 縱向轉發(延 1 拍)
//   c_valid / c_out           dump 輸出(signed INT32)
//
// 系統位置:
//   上游:GLB / memory 載入路徑供應 A/B tile 與 bitmask;控制訊號
//        (in_valid / cur_n / first_pass / dump_*)由 dataflow 控制器
//        產生(現階段由 testbench 驅動)。
//   下游:c_out → GLB 寫回;b_vec_out → 下一條 PE row(B 縱向鏈)。
//
// S8a 壓縮(tree 16 lane → 4 筆 banked write):
//   依序收集 tree 輸出的前 4 個 valid 段,連同對應 out_addr 送入 buffer。
//   假設同一拍 ≤4 段且落在互異 bank(Dense IP 恆為 1 段,自然滿足);
//   超出的段會被捨棄,須由上游 dataflow 保證不發生。
//
// 現況:
//   MFIU(mfiu_row)與 distribution(dist_net_row)為介面相容的 Dense
//   pass-through 實作;接入真實 sparse 版本時更新 trapezoid_pkg 的對應
//   *_STAGES 參數即可重新對齊。架構細節見 docs/pe-row-full-architecture.md。
// =============================================================================

module pe_row_full
    import trapezoid_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,

    // ── control ──
    input  logic [1:0]                              dataflow_sel,
    input  logic                                    in_valid,
    input  logic [LOCAL_BUF_AW-1:0]                 cur_n,
    input  logic                                    first_pass,
    input  logic                                    dump_en,
    input  logic [LOCAL_BUF_AW-1:0]                 dump_addr,

    // ── A: row-stationary + bitmask ──
    input  logic signed [N_MUL_ROW-1:0][DATA_W-1:0] a_vec,
    input  logic        [N_MUL_ROW-1:0]             a_bitmask,

    // ── B: from previous row + bitmask ──
    input  logic signed [N_MUL_ROW-1:0][DATA_W-1:0] b_vec_in,
    input  logic        [N_MUL_ROW-1:0]             b_bitmask_in,

    // ── B forwarding to next row ──
    output logic signed [N_MUL_ROW-1:0][DATA_W-1:0] b_vec_out,
    output logic        [N_MUL_ROW-1:0]             b_bitmask_out,
    output logic                                    b_valid_out,

    // ── C output ──
    output logic                                    c_valid,
    output logic signed [ACC_W-1:0]                 c_out
);

    // internal pipeline advances freely
    wire en = 1'b1;

    // delay depths (align control signals to the data path)
    localparam int DLY_AB   = MFIU_STAGES;                            // 3
    localparam int DLY_CUT  = DIST_STAGES + MUL_STAGES;               // 2
    localparam int DLY_ADDR = DIST_STAGES + MUL_STAGES + TREE_STAGES; // 3
    localparam int DLY_FP   = 1 + MFIU_STAGES + DIST_STAGES + MUL_STAGES + TREE_STAGES; // 7: align first_pass from input to acc_en

    // =====================================================================
    // S1: input latch (A-reg / B-FIFO latch function)
    // =====================================================================
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] a_q, b_q;
    logic        [N_MUL_ROW-1:0]             a_bm_q, b_bm_q;
    logic [LOCAL_BUF_AW-1:0]                 cur_n_q;
    logic                                    v_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_q <= '0; b_q <= '0; a_bm_q <= '0; b_bm_q <= '0;
            cur_n_q <= '0; v_q <= 1'b0;
        end else if (en) begin
            a_q <= a_vec; b_q <= b_vec_in;
            a_bm_q <= a_bitmask; b_bm_q <= b_bitmask_in;
            cur_n_q <= cur_n; v_q <= in_valid;
        end
    end

    // =====================================================================
    // S2-S4: MFIU (mfiu_row; multi-fiber core see mfiu.v)
    // =====================================================================
    logic [N_MUL_ROW-1:0][4:0]              mfiu_idx;
    logic [4:0]                             mfiu_cnt;
    logic [N_MUL_ROW-2:0]                   mfiu_cut;
    logic [N_MUL_ROW-1:0][LOCAL_BUF_AW-1:0] mfiu_addr;
    logic                                   mfiu_vld;

    mfiu_row u_mfiu (
        .clk             (clk),
        .rst_n           (rst_n),
        .en              (en),
        .in_valid        (v_q),
        .dataflow_sel    (dataflow_sel),
        .cur_n           (cur_n_q),
        .a_bitmask       (a_bm_q),
        .b_bitmask       (b_bm_q),
        .effectual_idx   (mfiu_idx),
        .effectual_count (mfiu_cnt),
        .cut_after       (mfiu_cut),
        .out_addr        (mfiu_addr),
        .meta_valid      (mfiu_vld)
    );

    // ── delay A/B values by MFIU_STAGES cycles to align with MFIU output ──
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] a_dly [DLY_AB];
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] b_dly [DLY_AB];
    integer da;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (da = 0; da < DLY_AB; da = da + 1) begin
                a_dly[da] <= '0; b_dly[da] <= '0;
            end
        end else if (en) begin
            a_dly[0] <= a_q; b_dly[0] <= b_q;
            for (da = 1; da < DLY_AB; da = da + 1) begin
                a_dly[da] <= a_dly[da-1];
                b_dly[da] <= b_dly[da-1];
            end
        end
    end
    wire signed [N_MUL_ROW-1:0][DATA_W-1:0] a_aligned = a_dly[DLY_AB-1];
    wire signed [N_MUL_ROW-1:0][DATA_W-1:0] b_aligned = b_dly[DLY_AB-1];

    // =====================================================================
    // S5: A/B Distribution network (Benes, NoC)
    // =====================================================================
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] dist_a, dist_b;
    logic                                    dist_vld;

    dist_net_row u_dist (
        .clk           (clk),
        .rst_n         (rst_n),
        .en            (en),
        .in_valid      (mfiu_vld),
        .dataflow_sel  (dataflow_sel),
        .a_vec_in      (a_aligned),
        .b_vec_in      (b_aligned),
        .effectual_idx (mfiu_idx),
        .a_vec_out     (dist_a),
        .b_vec_out     (dist_b),
        .out_valid     (dist_vld)
    );

    // =====================================================================
    // S6: Mul × 16 (mac_unit)
    // =====================================================================
    logic signed [N_MUL_ROW-1:0][PROD_W-1:0] partials;

    genvar gi;
    generate
        for (gi = 0; gi < N_MUL_ROW; gi = gi + 1) begin : g_mul
            mac_unit u_mul (
                .clk     (clk),
                .rst_n   (rst_n),
                .en      (en),
                .a       (dist_a[gi]),
                .b       (dist_b[gi]),
                .product (partials[gi])
            );
        end
    endgenerate

    logic mul_vld;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) mul_vld <= 1'b0;
        else if (en) mul_vld <= dist_vld;
    end

    // ── delay cut_after by DLY_CUT cycles to align with partials entering tree ──
    logic [N_MUL_ROW-2:0] cut_dly [DLY_CUT];
    integer dc;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (dc = 0; dc < DLY_CUT; dc = dc + 1) cut_dly[dc] <= '0;
        end else if (en) begin
            cut_dly[0] <= mfiu_cut;
            for (dc = 1; dc < DLY_CUT; dc = dc + 1) cut_dly[dc] <= cut_dly[dc-1];
        end
    end
    wire [N_MUL_ROW-2:0] cut_aligned = cut_dly[DLY_CUT-1];

    // =====================================================================
    // S7: reduction tree (flexagon)
    // =====================================================================
    logic signed [N_MUL_ROW-1:0][ACC_W-1:0] tree_sums;
    logic        [N_MUL_ROW-1:0]            tree_valid_pos;

    reduction_tree_radix16 u_tree (
        .clk           (clk),
        .rst_n         (rst_n),
        .en            (en),
        .partials      (partials),
        .cut_after     (cut_aligned),
        .subtree_sums  (tree_sums),
        .subtree_valid (tree_valid_pos)
    );

    logic tree_out_vld;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) tree_out_vld <= 1'b0;
        else if (en) tree_out_vld <= mul_vld;
    end

    // ── delay out_addr by DLY_ADDR cycles to align with tree output entering buffer ──
    logic [N_MUL_ROW-1:0][LOCAL_BUF_AW-1:0] addr_dly [DLY_ADDR];
    integer dd;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (dd = 0; dd < DLY_ADDR; dd = dd + 1) addr_dly[dd] <= '0;
        end else if (en) begin
            addr_dly[0] <= mfiu_addr;
            for (dd = 1; dd < DLY_ADDR; dd = dd + 1) addr_dly[dd] <= addr_dly[dd-1];
        end
    end
    wire [N_MUL_ROW-1:0][LOCAL_BUF_AW-1:0] addr_aligned = addr_dly[DLY_ADDR-1];

    // ── delay first_pass from input by DLY_FP cycles to align with buffer write (= acc_en/tree_out_vld instant) ──
    logic fp_dly [DLY_FP];
    integer df;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (df = 0; df < DLY_FP; df = df + 1) fp_dly[df] <= 1'b0;
        end else if (en) begin
            fp_dly[0] <= first_pass;
            for (df = 1; df < DLY_FP; df = df + 1) fp_dly[df] <= fp_dly[df-1];
        end
    end
    wire fp_aligned = fp_dly[DLY_FP-1];

    // =====================================================================
    // S8a: 16→4 compaction (16 tree sub-trees → up to 4 banked write requests)
    // =====================================================================
    //   v1: collect the first 4 valid in order (Dense has only 1 → trivially correct)
    //   assumption: ≤4 valid per cycle landing in distinct banks; TrIP >4 / same-bank serialization → TODO
    logic                    ts_v    [N_MUL_ROW];
    logic signed [ACC_W-1:0] ts_sum  [N_MUL_ROW];
    logic [LOCAL_BUF_AW-1:0] ts_addr [N_MUL_ROW];
    genvar gt;
    generate
        for (gt = 0; gt < N_MUL_ROW; gt = gt + 1) begin : g_un_tree
            assign ts_v[gt]    = tree_valid_pos[gt];
            assign ts_sum[gt]  = tree_sums[gt];
            assign ts_addr[gt] = addr_aligned[gt];
        end
    endgenerate

    logic                    wr_v_u    [N_BANK_LBUF];
    logic signed [ACC_W-1:0] wr_sum_u  [N_BANK_LBUF];
    logic [LOCAL_BUF_AW-1:0] wr_addr_u [N_BANK_LBUF];
    integer ci, lane;
    always_comb begin
        for (ci = 0; ci < N_BANK_LBUF; ci = ci + 1) begin
            wr_v_u[ci] = 1'b0; wr_sum_u[ci] = '0; wr_addr_u[ci] = '0;
        end
        lane = 0;
        for (ci = 0; ci < N_MUL_ROW; ci = ci + 1) begin
            if (ts_v[ci] && (lane < N_BANK_LBUF)) begin
                wr_v_u[lane]    = 1'b1;
                wr_sum_u[lane]  = ts_sum[ci];
                wr_addr_u[lane] = ts_addr[ci];
                lane = lane + 1;
            end
        end
    end

    logic        [N_BANK_LBUF-1:0]                   wr_valid;
    logic signed [N_BANK_LBUF-1:0][ACC_W-1:0]        wr_sum;
    logic        [N_BANK_LBUF-1:0][LOCAL_BUF_AW-1:0] wr_addr;
    generate
        for (gt = 0; gt < N_BANK_LBUF; gt = gt + 1) begin : g_pack
            assign wr_valid[gt] = wr_v_u[gt];
            assign wr_sum[gt]   = wr_sum_u[gt];
            assign wr_addr[gt]  = wr_addr_u[gt];
        end
    endgenerate

    // =====================================================================
    // S8b: Local Buffer (4-bank banked accumulator) + C out
    // =====================================================================
    local_buffer_row u_buf (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (en),
        .wr_valid   (wr_valid),
        .wr_sum     (wr_sum),
        .wr_addr    (wr_addr),
        .first_pass (fp_aligned),
        .acc_en     (tree_out_vld),
        .dump_en    (dump_en),
        .dump_addr  (dump_addr),
        .c_valid    (c_valid),
        .c_out      (c_out)
    );

    // =====================================================================
    // B forwarding: delay b_vec_in by 1 cycle to next row (Fig 7 ④)
    // =====================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_vec_out <= '0; b_bitmask_out <= '0; b_valid_out <= 1'b0;
        end else if (en) begin
            b_vec_out <= b_vec_in; b_bitmask_out <= b_bitmask_in; b_valid_out <= in_valid;
        end
    end

    // effectual_count unused in Dense IP (=16), suppress lint
    wire _unused = &{1'b0, mfiu_cnt};

endmodule
