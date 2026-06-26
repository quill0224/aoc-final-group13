// =============================================================================
// pe_row_tail.sv - multiply, segmented reduction, and accumulation
// =============================================================================
// Multiplies 16 gathered operand pairs, reduces contiguous lanes belonging to
// the same output column, and accumulates up to four segment sums into the
// per-row local buffer.
//
// lane_col determines the segment boundaries. Invalid trailing lanes inherit
// the last valid column so a segment ending at lane 15 keeps the correct
// address. Buffer address = cur_n_base + lane_col.
//
// Pipeline:
//   T    crossbar output and segment metadata
//   T+1  registered products
//   T+2  registered segment sums and buffer request
// =============================================================================

module pe_row_tail
    import trapezoid_pkg::*;
(
    input  logic                     clk,
    input  logic                     rst_n,

    // Crossbar output
    input  logic                     in_valid,
    input  logic [7:0]               a_val      [0:15],
    input  logic [7:0]               b_val      [0:15],
    input  logic [3:0]               lane_col   [0:15],
    input  logic                     lane_valid [0:15],

    // Accumulation and dump control
    input  logic                     first_pass,
    input  logic [LOCAL_BUF_AW-1:0]  cur_n_base,
    input  logic                     dump_en,
    input  logic [LOCAL_BUF_AW-1:0]  dump_addr,

    // Dump output
    output logic                     c_valid,
    output logic signed [ACC_W-1:0]  c_out
);

    // The datapath runs continuously; validity is tracked separately.
    wire en = 1'b1;

    // Control-delay lengths matching the multiplier and tree registers.
    localparam int DLY_CUT  = MUL_STAGES;
    localparam int DLY_ADDR = MUL_STAGES + TREE_STAGES;
    localparam int CW       = 4;

    // =====================================================================
    // Segment boundaries and output-column metadata.
    // =====================================================================
    logic [N_MUL_ROW-2:0] cut_comb;
    genvar gu;
    generate
        for (gu = 0; gu < N_MUL_ROW-1; gu = gu + 1) begin : g_cut
            assign cut_comb[gu] = lane_valid[gu] & lane_valid[gu+1]
                                & (lane_col[gu] != lane_col[gu+1]);
        end
    endgenerate

    // Invalid trailing lanes inherit the last valid output column.
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
                out_col[io] = last_col;
            end
        end
    end

    // Suppress buffer writes for an empty intersection.
    logic has_match_comb;
    integer ih;
    always_comb begin
        has_match_comb = 1'b0;
        for (ih = 0; ih < N_MUL_ROW; ih = ih + 1) has_match_comb |= lane_valid[ih];
    end

    // Pack column metadata for the delay line.
    logic [N_MUL_ROW*CW-1:0] off_flat;
    generate
        for (gu = 0; gu < N_MUL_ROW; gu = gu + 1) begin : g_off_pack
            assign off_flat[gu*CW +: CW] = out_col[gu];
        end
    endgenerate

    // =====================================================================
    // Control delay lines
    // =====================================================================
    // Align segment boundaries with registered products.
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

    // Align buffer metadata with registered tree outputs.
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

    // Valid pipeline through multiplier and tree registers.
    logic v_s6, v_s7;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin v_s6 <= 1'b0; v_s7 <= 1'b0; end
        else if (en) begin v_s6 <= in_valid; v_s7 <= v_s6; end
    end

    // =====================================================================
    // Sixteen registered multipliers
    // =====================================================================
    logic signed [N_MUL_ROW-1:0][PROD_W-1:0] partials;
    genvar gi;
    generate
        for (gi = 0; gi < N_MUL_ROW; gi = gi + 1) begin : g_mul
            mac_unit u_mul (
                .clk     (clk),
                .rst_n   (rst_n),
                .en      (en),
                .a       (a_val[gi]),
                .b       (b_val[gi]),
                .product (partials[gi])
            );
        end
    endgenerate

    // =====================================================================
    // Segmented reduction
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
    // Compact segment results into four local-buffer requests.
    // =====================================================================
    logic                    ts_v    [N_MUL_ROW];
    logic signed [ACC_W-1:0] ts_sum  [N_MUL_ROW];
    logic [LOCAL_BUF_AW-1:0] ts_addr [N_MUL_ROW];
    genvar gt;
    generate
        for (gt = 0; gt < N_MUL_ROW; gt = gt + 1) begin : g_un_tree
            assign ts_v[gt]   = tree_valid_pos[gt];
            assign ts_sum[gt] = tree_sums[gt];
            // Convert the tile-local column to a local-buffer address.
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
    // Per-row accumulation buffer
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
