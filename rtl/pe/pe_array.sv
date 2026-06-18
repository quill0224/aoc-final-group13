// =============================================================================
// pe_array.sv — 16 × PE row 陣列(systolic,B 縱向鏈)
// =============================================================================
// 功能:
//   instantiate N_PE_ROW 條 pe_row_full,組成 16×16 = 256 MAC 的運算陣列。
//   row i 算輸出矩陣的第 i 列 C[i, :]。
//     A:row-stationary —— 每條 row 吃自己的 a_vec(由 a_grid[i] 餵),駐留不動。
//     B:縱向鏈 —— 從 row 0 進,每條 row 把 B 延 1 拍傳給下一條(pe_row_full
//        的 b_vec_out);16 條 row 重用同一份 B(只從 GLB 讀一次)。
//     C:每條 row 各算各的 → c_out[i],dump 時一次讀出一整個 column。
//
// 控制錯拍(systolic 關鍵):
//   B 到 row i 比 row 0 晚 i 拍,故 row i 的 in_valid / cur_n / first_pass 也要
//   晚 i 拍才對得上:
//     in_valid : 直接用上一條 row 的 b_valid_out(B 鏈自帶 valid,延 1/row)
//     cur_n / first_pass : 本層做延遲鏈,row i 拿延 i 拍的版本
//   dataflow_sel:全域廣播。dump_en/dump_addr:dump 階段廣播(此時無 compute,
//   16 條 row 同步讀出同一 column → c_out 即該 column 跨 row 的 16 個值)。
//
// 介面:
//   dataflow_sel / in_valid / cur_n / first_pass / dump_en / dump_addr  控制(餵 row 0)
//   a_grid     [N_PE_ROW][N_MUL_ROW][DATA_W]  in   每條 row 的 row-stationary A
//   a_bm_grid  [N_PE_ROW][N_MUL_ROW]          in   每條 row 的 A bitmask
//   b_vec_top  [N_MUL_ROW][DATA_W]            in   進 row 0 的 B(其餘 row 由鏈傳)
//   b_bm_top   [N_MUL_ROW]                    in   進 row 0 的 B bitmask
//   c_out      [N_PE_ROW][ACC_W]              out  dump 時各 row 的 C 值(一個 column)
//   c_valid                                   out  dump 結果有效(各 row 同步)
//
// 現況:Dense IP(MFIU/dist 為 stand-in);真版到位 TrIP 直接亮,本檔不用改
//   (row 內部介面凍結)。
// =============================================================================

module pe_array
    import trapezoid_pkg::*;
(
    input  logic                                                  clk,
    input  logic                                                  rst_n,

    // ── Control (drive row 0; array auto-skews it downward per row) ──
    input  logic [1:0]                                            dataflow_sel,
    input  logic                                                  in_valid,
    input  logic [LOCAL_BUF_AW-1:0]                               cur_n,
    input  logic                                                  first_pass,
    input  logic                                                  dump_en,
    input  logic [LOCAL_BUF_AW-1:0]                               dump_addr,

    // ── A: row-stationary, one set per row ──
    input  logic signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0] a_grid,
    input  logic        [N_PE_ROW-1:0][N_MUL_ROW-1:0]             a_bm_grid,

    // ── B: feed row 0 only; other rows receive it via the vertical chain ──
    input  logic signed [N_MUL_ROW-1:0][DATA_W-1:0]               b_vec_top,
    input  logic        [N_MUL_ROW-1:0]                           b_bm_top,

    // ── C output (on dump, one column spanning 16 rows) ──
    output logic [N_PE_ROW-1:0][ACC_W-1:0]                        c_out,
    output logic                                                  c_valid
);

    // =====================================================================
    // Control skew chain: cur_n_d[i] / fp_d[i] = input delayed (i+1) cycles
    //   row 0 uses the raw input (delay 0); row i (>0) uses cur_n_d[i-1] (= delay i)
    // =====================================================================
    logic [LOCAL_BUF_AW-1:0] cur_n_d [N_PE_ROW];
    logic                    fp_d    [N_PE_ROW];
    integer di;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (di = 0; di < N_PE_ROW; di = di + 1) begin
                cur_n_d[di] <= '0; fp_d[di] <= 1'b0;
            end
        end else begin
            cur_n_d[0] <= cur_n; fp_d[0] <= first_pass;
            for (di = 1; di < N_PE_ROW; di = di + 1) begin
                cur_n_d[di] <= cur_n_d[di-1];
                fp_d[di]    <= fp_d[di-1];
            end
        end
    end

    // =====================================================================
    // B vertical chain + per-row output wires
    // =====================================================================
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] bchain_vec [N_PE_ROW];
    logic        [N_MUL_ROW-1:0]             bchain_bm  [N_PE_ROW];
    logic                                    bchain_vld [N_PE_ROW];

    // Per-row "input" source (row 0 = external; row i = previous row's chain / skewed control)
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] row_bvi [N_PE_ROW];
    logic        [N_MUL_ROW-1:0]             row_bbi [N_PE_ROW];
    logic                                    row_ivi [N_PE_ROW];
    logic [LOCAL_BUF_AW-1:0]                 row_cni [N_PE_ROW];
    logic                                    row_fpi [N_PE_ROW];

    genvar gr;
    generate
        for (gr = 0; gr < N_PE_ROW; gr = gr + 1) begin : g_src
            if (gr == 0) begin : g_head
                assign row_bvi[gr] = b_vec_top;
                assign row_bbi[gr] = b_bm_top;
                assign row_ivi[gr] = in_valid;
                assign row_cni[gr] = cur_n;
                assign row_fpi[gr] = first_pass;
            end else begin : g_chain
                assign row_bvi[gr] = bchain_vec[gr-1];
                assign row_bbi[gr] = bchain_bm[gr-1];
                assign row_ivi[gr] = bchain_vld[gr-1];   // B chain carries its own valid (delay 1/row)
                assign row_cni[gr] = cur_n_d[gr-1];       // = delay gr cycles
                assign row_fpi[gr] = fp_d[gr-1];
            end
        end
    endgenerate

    // =====================================================================
    // 16 PE rows
    // =====================================================================
    logic [N_PE_ROW-1:0] cvld;
    generate
        for (gr = 0; gr < N_PE_ROW; gr = gr + 1) begin : g_row
            pe_row_full u_row (
                .clk           (clk),
                .rst_n         (rst_n),
                .dataflow_sel  (dataflow_sel),
                .in_valid      (row_ivi[gr]),
                .cur_n         (row_cni[gr]),
                .first_pass    (row_fpi[gr]),
                .dump_en       (dump_en),       // dump broadcast
                .dump_addr     (dump_addr),
                .a_vec         (a_grid[gr]),
                .a_bitmask     (a_bm_grid[gr]),
                .b_vec_in      (row_bvi[gr]),
                .b_bitmask_in  (row_bbi[gr]),
                .b_vec_out     (bchain_vec[gr]),
                .b_bitmask_out (bchain_bm[gr]),
                .b_valid_out   (bchain_vld[gr]),
                .c_valid       (cvld[gr]),
                .c_out         (c_out[gr])
            );
        end
    endgenerate

    // All rows dump in sync (broadcast dump) → use row 0 as representative
    assign c_valid = cvld[0];

endmodule
