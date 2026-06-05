// =============================================================================
// pe_row_full.sv — 完整 PE Row(paper Fig 6 全包版,8-stage 單一物理 pipeline)
// =============================================================================
// === 模組 OWNER: 黃妍心 ===
//
// 用途:
//   paper Fig 6 完整 PE row,包進所有 per-row 硬體:
//     S1     輸入打拍 (A-reg / B-FIFO 的 latch 功能)
//     S2-S4  MFIU (mfiu_row,楊承豫 multi-fiber body)→ effectual_idx / cut_after / out_addr
//     S5     A/B Distribution network (dist_net_row,Benes,NoC)
//     S6     Mul × 16 (mac_unit)
//     S7     Merge-Reduction Tree (merge_tree_radix16_flexagon)
//     S8     Local Buffer (local_buffer_row) scatter-accumulate + C out
//   + B 跨 row vertical forwarding (Fig 7 step ④)
//
//   詳見 docs/pe-row-full-architecture.md
//
// === 單一物理 pipeline(Δ5 Option A)===
//   Dense IP 也走 MFIU + dist(pass-through),latency = PE_ROW_STAGES = 8。
//   組員 MFIU / dist 真實 body 一到位,TrIP 直接亮,本檔不用改。
//
// === 控制訊號對齊(本檔的核心難點)===
//   MFIU metadata 在 S4 算出,但被不同 stage 消費,所以要 delay 對齊資料路徑:
//     - effectual_idx → S5 dist 立即用(對齊)
//     - cut_after     → S7 tree 用,延 DIST+MUL = 2 拍
//     - out_addr      → S8 buffer 用,延 DIST+MUL+TREE = 3 拍
//   A/B 值在 S1 latch 後,延 MFIU_STAGES 拍對齊 MFIU 輸出,再進 dist。
//
// === 對外控制(由 dataflow_ctrl 提供;Phase 1 由 tb 驅動)===
//   - cur_n      : 當前 output column(Dense IP:單一 C 寫 buffer[cur_n])
//   - in_valid   : a/b 此 cycle 有效
//   - first_pass : 該 column 的「第一段 K」→ buffer 覆蓋(等效清零);後續 K → 累加
//                  (取代舊 buf_clear;會在 pe_row 內延遲對齊到 buffer 寫入時點)
//   - dump_en/dump_addr : 某 column 的 K-tile 全累加完,讀出寫回
//     ⚠️ dump_en 必須等該 column 最後一拍 in_valid 之後 (PE_ROW_STAGES+1) 拍才拉
//        (dataflow_ctrl 依 PE_ROW_STAGES 算 timing)
// =============================================================================

module pe_row_full
    import trapezoid_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,

    // ── 控制 ──
    input  logic [1:0]                              dataflow_sel,
    input  logic                                    in_valid,
    input  logic [LOCAL_BUF_AW-1:0]                 cur_n,
    input  logic                                    first_pass,
    input  logic                                    dump_en,
    input  logic [LOCAL_BUF_AW-1:0]                 dump_addr,

    // ── A:row-stationary + bitmask ──
    input  logic signed [N_MUL_ROW-1:0][DATA_W-1:0] a_vec,
    input  logic        [N_MUL_ROW-1:0]             a_bitmask,

    // ── B:從上一條 row 進 + bitmask ──
    input  logic signed [N_MUL_ROW-1:0][DATA_W-1:0] b_vec_in,
    input  logic        [N_MUL_ROW-1:0]             b_bitmask_in,

    // ── B forwarding 給下一條 row ──
    output logic signed [N_MUL_ROW-1:0][DATA_W-1:0] b_vec_out,
    output logic        [N_MUL_ROW-1:0]             b_bitmask_out,
    output logic                                    b_valid_out,

    // ── C 輸出 ──
    output logic                                    c_valid,
    output logic signed [ACC_W-1:0]                 c_out
);

    // 內部 pipeline 自由推進
    wire en = 1'b1;

    // delay 深度(控制訊號對齊資料路徑)
    localparam int DLY_AB   = MFIU_STAGES;                            // 3
    localparam int DLY_CUT  = DIST_STAGES + MUL_STAGES;               // 2
    localparam int DLY_ADDR = DIST_STAGES + MUL_STAGES + TREE_STAGES; // 3
    localparam int DLY_FP   = 1 + MFIU_STAGES + DIST_STAGES + MUL_STAGES + TREE_STAGES; // 7:first_pass 從 input 對齊到 acc_en

    // =====================================================================
    // S1:輸入打拍(A-reg / B-FIFO 的 latch 功能)
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
    // S2-S4:MFIU(介面 黃妍心;multi-fiber body 楊承豫)
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

    // ── A/B 值延 MFIU_STAGES 拍,對齊 MFIU 輸出 ──
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
    // S5:A/B Distribution network(Benes,NoC)
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
    // S6:Mul × 16(mac_unit)
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

    // ── cut_after 延 DLY_CUT 拍,對齊 partials 進 tree ──
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
    // S7:Merge-Reduction Tree(flexagon)
    // =====================================================================
    logic signed [N_MUL_ROW-1:0][ACC_W-1:0] tree_sums;
    logic        [N_MUL_ROW-1:0]            tree_valid_pos;

    merge_tree_radix16_flexagon u_tree (
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

    // ── out_addr 延 DLY_ADDR 拍,對齊 tree 輸出進 buffer ──
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

    // ── first_pass 從 input 延 DLY_FP 拍,對齊到 buffer 寫入(= acc_en/tree_out_vld 時點)──
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
    // S8a:16→4 壓縮(tree 16 個 sub-tree → 最多 4 筆 banked write request)
    // =====================================================================
    //   v1:依序收前 4 個 valid(Dense 只有 1 個 → trivially 對)
    //   假設:同拍 ≤4 個 valid 且落不同 bank;TrIP >4 / 同 bank 序列化 → TODO
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
    // S8b:Local Buffer(4-bank banked accumulator)+ C out
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
    // B forwarding:b_vec_in 延 1 cycle 給下一條 row(Fig 7 ④)
    // =====================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_vec_out <= '0; b_bitmask_out <= '0; b_valid_out <= 1'b0;
        end else if (en) begin
            b_vec_out <= b_vec_in; b_bitmask_out <= b_bitmask_in; b_valid_out <= in_valid;
        end
    end

    // effectual_count 在 Dense IP 沒用到(=16),抑制 lint
    wire _unused = &{1'b0, mfiu_cnt};

endmodule
