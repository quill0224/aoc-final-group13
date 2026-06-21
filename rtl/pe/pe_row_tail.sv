// =============================================================================
// pe_row_tail.sv — PE row 尾段 (mac×16 + reduction + output accumulate)  [Step B-3]
// =============================================================================
// 接 crossbar 的 per-lane 壓縮值,完成一個 PE row 的後段運算:
//   S6  mac×16        : product[l] = uint8(a_val[l]) × int8(b_val[l])
//   S7  reduction tree: 依 cut_after 把「同一輸出欄」的連續 lane 加成一個 partial
//   S8a 16→4 壓縮     : 取出 ≤4 個 segment 和 + 各自輸出欄位址(off 繼承無效尾)
//   S8b local_buffer  : 跨 K-tile 累加(first_pass 覆寫 / 否則 RMW),dump 讀出
//
//   * 一個 PE row 一顆;lite 設計 bank = 輸出欄(1 A-row / PE row)。
//   * 重用 mac_unit / reduction_tree_radix16 / local_buffer_row(皆已驗證)。
//   * 無效尾 lane(crossbar 設 lane_col=0)用 off 繼承:沿用 pe_row_full S8a,
//     合併段 dump 在 lane15 時帶最後一個有效欄,不會誤送到第 0 欄。
//   * Option A(配合 controller 迴圈順序 M→K→N,K 中 N 內):buffer 同時 hold
//     整列所有 N 欄、撐過整個 K 迴圈,到 K 全累加完(controller global_flush)才逐欄
//     dump。位址 = cur_n_base(=n_cnt*16) + out_col。dump_en 不可與 acc_en 同拍。
//
// pipeline:
//   crossbar(comb,T) → mac(T+1) → tree(T+2) → S8a/buf(@T+2)
//   cut_after                : 延遲 DLY_CUT =1 對齊 tree 的 partials
//   out_col/has_match/first_pass/cur_n_base : 延遲 DLY_ADDR=2 對齊 S8a/buffer 寫入
// =============================================================================

module pe_row_tail
    import trapezoid_pkg::*;
(
    input  logic                     clk,
    input  logic                     rst_n,

    // ── from crossbar (B-2) ── 沿用既有名稱
    input  logic                     in_valid,           // = crossbar.valid_out(本拍有一個 group)
    input  logic [7:0]               a_val      [0:15],  // uint8 → mac.a
    input  logic [7:0]               b_val      [0:15],  // 帶 int8 → mac.b(port 端 re-sign)
    input  logic [3:0]               lane_col   [0:15],  // tile 內真實輸出欄 0..15
    input  logic                     lane_valid [0:15],

    // ── from controller (src/controller.sv) ──
    input  logic                     first_pass,         // = (k_cnt==0):該欄第一個 K-tile→覆寫;否則累加
    input  logic [LOCAL_BUF_AW-1:0]  cur_n_base,         // = n_cnt * N_TILE_SIZE:本 N-tile 的基底欄
    input  logic                     dump_en,            // K 全累加完(global_flush)後逐欄讀出;不可與 acc 同拍
    input  logic [LOCAL_BUF_AW-1:0]  dump_addr,          // 0..N_tiles*16-1

    // ── output (= dump 讀出,給 golden 比對 / GLB)──
    output logic                     c_valid,
    output logic signed [ACC_W-1:0]  c_out
);

    // 內部管線恆前進(沿用 pe_row_full 慣例)
    wire en = 1'b1;

    // 延遲深度(對齊控制訊號到資料路;crossbar 純組合 → 比 pe_row_full 少一級 dist)
    localparam int DLY_CUT  = MUL_STAGES;                 // 1: crossbar 輸出 → tree 的 partials
    localparam int DLY_ADDR = MUL_STAGES + TREE_STAGES;   // 2: → S8a / buffer 寫入
    localparam int CW       = 4;                          // 輸出欄寬(0..15)

    // =====================================================================
    // 分組 metadata(組合,在 crossbar 輸出當拍 T)
    //   cut_after[i] = 相鄰有效 lane 屬不同輸出欄 → 在 i 與 i+1 間切段
    //   out_col[l]   = 該 lane 的輸出欄;無效尾 lane 繼承最後一個有效欄
    // =====================================================================
    logic [N_MUL_ROW-2:0] cut_comb;
    genvar gu;
    generate
        for (gu = 0; gu < N_MUL_ROW-1; gu = gu + 1) begin : g_cut
            assign cut_comb[gu] = lane_valid[gu] & lane_valid[gu+1]
                                & (lane_col[gu] != lane_col[gu+1]);
        end
    endgenerate

    // 每 lane 輸出欄(無效尾繼承)
    logic [CW-1:0] out_col [0:15];
    logic [CW-1:0] last_col;
    integer io;
    always_comb begin
        last_col = '0;
        for (io = 0; io < N_MUL_ROW; io = io + 1) begin
            if (lane_valid[io]) begin
                out_col[io] = lane_col[io];
                last_col    = lane_col[io];
            end else begin
                out_col[io] = last_col;   // 無效尾 → 繼承,避免 lane_col=0 誤送第 0 欄
            end
        end
    end

    // 有無任何有效 lane(無 match 不寫 buffer)
    logic has_match_comb;
    integer ih;
    always_comb begin
        has_match_comb = 1'b0;
        for (ih = 0; ih < N_MUL_ROW; ih = ih + 1) has_match_comb |= lane_valid[ih];
    end

    // pack out_col → flat 給延遲線
    logic [N_MUL_ROW*CW-1:0] off_flat;
    generate
        for (gu = 0; gu < N_MUL_ROW; gu = gu + 1) begin : g_off_pack
            assign off_flat[gu*CW +: CW] = out_col[gu];
        end
    endgenerate

    // =====================================================================
    // 延遲線
    // =====================================================================
    // cut_after → DLY_CUT(對齊 tree 的 partials)
    logic [N_MUL_ROW-2:0] cut_dly [DLY_CUT];
    integer dc;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (dc = 0; dc < DLY_CUT; dc = dc + 1) cut_dly[dc] <= '0;
        end else if (en) begin
            cut_dly[0] <= cut_comb;
            for (dc = 1; dc < DLY_CUT; dc = dc + 1) cut_dly[dc] <= cut_dly[dc-1];
        end
    end
    wire [N_MUL_ROW-2:0] cut_aligned = cut_dly[DLY_CUT-1];

    // out_col / has_match / first_pass / cur_n_base → DLY_ADDR(對齊 S8a / buffer 寫入)
    logic [N_MUL_ROW*CW-1:0] off_dly [DLY_ADDR];
    logic                    hm_dly  [DLY_ADDR];
    logic                    fp_dly  [DLY_ADDR];
    logic [LOCAL_BUF_AW-1:0] cnb_dly [DLY_ADDR];
    integer da;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (da = 0; da < DLY_ADDR; da = da + 1) begin
                off_dly[da] <= '0; hm_dly[da] <= 1'b0; fp_dly[da] <= 1'b0; cnb_dly[da] <= '0;
            end
        end else if (en) begin
            off_dly[0] <= off_flat; hm_dly[0] <= has_match_comb; fp_dly[0] <= first_pass; cnb_dly[0] <= cur_n_base;
            for (da = 1; da < DLY_ADDR; da = da + 1) begin
                off_dly[da] <= off_dly[da-1];
                hm_dly[da]  <= hm_dly[da-1];
                fp_dly[da]  <= fp_dly[da-1];
                cnb_dly[da] <= cnb_dly[da-1];
            end
        end
    end
    wire [N_MUL_ROW*CW-1:0] off_aligned        = off_dly[DLY_ADDR-1];
    wire                    has_match_aligned  = hm_dly[DLY_ADDR-1];
    wire                    fp_aligned         = fp_dly[DLY_ADDR-1];
    wire [LOCAL_BUF_AW-1:0] cur_n_base_aligned = cnb_dly[DLY_ADDR-1];

    // valid pipe:in_valid → (T+1) mac → (T+2) tree
    logic v_s6, v_s7;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin v_s6 <= 1'b0; v_s7 <= 1'b0; end
        else if (en) begin v_s6 <= in_valid; v_s7 <= v_s6; end
    end

    // =====================================================================
    // S6: Mul × 16(product 直接寫進 packed partials 即完成 unpacked→packed 打包)
    // =====================================================================
    logic signed [N_MUL_ROW-1:0][PROD_W-1:0] partials;
    genvar gi;
    generate
        for (gi = 0; gi < N_MUL_ROW; gi = gi + 1) begin : g_mul
            mac_unit u_mul (
                .clk     (clk),
                .rst_n   (rst_n),
                .en      (en),
                .a       (a_val[gi]),     // uint8
                .b       (b_val[gi]),     // int8(crossbar 端為 unsigned bus,mac port re-sign)
                .product (partials[gi])
            );
        end
    endgenerate

    // =====================================================================
    // S7: reduction tree — cut_after 來自 B-fiber(輸出欄)分組
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

    // =====================================================================
    // S8a: 16→4 壓縮 — 每段 out_addr = cur_n_base + out_col(Option A)
    // =====================================================================
    logic                    ts_v    [N_MUL_ROW];
    logic signed [ACC_W-1:0] ts_sum  [N_MUL_ROW];
    logic [LOCAL_BUF_AW-1:0] ts_addr [N_MUL_ROW];
    genvar gt;
    generate
        for (gt = 0; gt < N_MUL_ROW; gt = gt + 1) begin : g_un_tree
            assign ts_v[gt]   = tree_valid_pos[gt];
            assign ts_sum[gt] = tree_sums[gt];
            // out_addr = cur_n_base(=n_cnt*16,低 4 位為 0) + out_col;bank=addr[1:0]=out_col[1:0]
            assign ts_addr[gt] = cur_n_base_aligned
                               + {{(LOCAL_BUF_AW-CW){1'b0}}, off_aligned[gt*CW +: CW]};
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
    // S8b: local buffer — acc_en 由 has_match 把關(無 match 不寫)
    // =====================================================================
    wire acc_en = v_s7 & has_match_aligned;

    local_buffer_row u_buf (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (en),
        .wr_valid   (wr_valid),
        .wr_sum     (wr_sum),
        .wr_addr    (wr_addr),
        .first_pass (fp_aligned),
        .acc_en     (acc_en),
        .dump_en    (dump_en),
        .dump_addr  (dump_addr),
        .c_valid    (c_valid),
        .c_out      (c_out)
    );

endmodule
