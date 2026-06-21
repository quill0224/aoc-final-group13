// =============================================================================
// pe_array.sv — 16 x PE row array (systolic, B vertical chain)
// =============================================================================
// Function:
//   Instantiate N_PE_ROW pe_row_full to form a 16x16 = 256 MAC array.
//   Row i computes output matrix row i, C[i, :].
//     A: row-stationary — each row consumes its own a_vec (fed by a_grid[i]),
//        held stationary.
//     B: vertical chain — enters at row 0; each row delays B by 1 cycle and
//        passes to the next (pe_row_full's b_vec_out); all 16 rows reuse the
//        same B (read from GLB once).
//     C: each row computes independently -> c_out[i]; dump reads out a whole
//        column at once.
//
// Control skew (systolic key point):
//   B reaches row i exactly i cycles later than row 0, so row i's in_valid /
//   cur_n / first_pass must also be skewed by i cycles to line up:
//     in_valid : take previous row's b_valid_out (B chain carries its own
//                valid, delayed 1/row)
//     cur_n / first_pass : delay chain in this layer; row i gets the version
//                          delayed i cycles
//   dataflow_sel: broadcast to all rows. dump_en/dump_addr: broadcast during
//   dump phase (no compute then; all 16 rows read the same column in sync ->
//   c_out is the 16 values of that column across rows).
//
// Interface:
//   dataflow_sel / in_valid / cur_n / first_pass / dump_en / dump_addr  control (drive row 0)
//   a_grid     [N_PE_ROW][N_A_FIBER][BITMASK_W][DATA_W] in row-stationary A (multi-fiber)
//   a_bm_grid  [N_PE_ROW][N_A_FIBER][BITMASK_W]         in A bitmask (multi-fiber)
//   b_vec_top  [N_B_FIBER][BITMASK_W][DATA_W]           in B bundle into row 0 (other rows via chain)
//   b_bm_top   [N_B_FIBER][BITMASK_W]                   in B bitmask bundle into row 0
//   c_out      [N_PE_ROW][ACC_W]              out  per-row C value on dump (one column)
//   c_valid                                   out  dump result valid (rows in sync)
//
// Status: Dense IP (MFIU/dist are stand-ins); when the real TrIP arrives it
//   drops in directly, no change needed here (row internal interface frozen).
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
    //   a_load_valid / a_clear are broadcast to all rows: one pulse loads every
    //   row's a_grid[gr] into its A register (load once, then hold).
    input  logic                                                  a_load_valid,
    input  logic signed [N_PE_ROW-1:0][N_A_FIBER-1:0][BITMASK_W-1:0][DATA_W-1:0] a_grid,
    input  logic        [N_PE_ROW-1:0][N_A_FIBER-1:0][BITMASK_W-1:0]             a_bm_grid,
    input  logic                                                  a_clear,

    // ── B: feed row 0 only; other rows receive it via the vertical chain ──
    input  logic signed [N_B_FIBER-1:0][BITMASK_W-1:0][DATA_W-1:0]               b_vec_top,
    input  logic        [N_B_FIBER-1:0][BITMASK_W-1:0]                           b_bm_top,

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
    logic signed [N_B_FIBER-1:0][BITMASK_W-1:0][DATA_W-1:0] bchain_vec [N_PE_ROW];
    logic        [N_B_FIBER-1:0][BITMASK_W-1:0]             bchain_bm  [N_PE_ROW];
    logic                                    bchain_vld [N_PE_ROW];

    // Per-row "input" source (row 0 = external; row i = previous row's chain / skewed control)
    logic signed [N_B_FIBER-1:0][BITMASK_W-1:0][DATA_W-1:0] row_bvi [N_PE_ROW];
    logic        [N_B_FIBER-1:0][BITMASK_W-1:0]             row_bbi [N_PE_ROW];
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
                .a_load_valid  (a_load_valid),  // broadcast: one pulse loads all rows' A
                .a_vec         (a_grid[gr]),
                .a_bitmask     (a_bm_grid[gr]),
                .a_clear       (a_clear),       // broadcast
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
