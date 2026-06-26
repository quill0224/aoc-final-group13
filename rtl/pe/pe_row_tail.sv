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
#(
    parameter bit BUCKET_REDUCE = 1'b1
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // Crossbar output
    input  logic                     in_valid,
    input  logic [16*8-1:0]          a_val_flat,
    input  logic [16*8-1:0]          b_val_flat,
    input  logic [16*4-1:0]          lane_col_flat,
    input  logic [16-1:0]            lane_valid_flat,

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

    logic [7:0] a_val [0:15];
    logic [7:0] b_val [0:15];
    logic [3:0] lane_col [0:15];
    logic       lane_valid [0:15];

    genvar gu;
    generate
        for (gu = 0; gu < N_MUL_ROW; gu = gu + 1) begin : g_unpack_inputs
            assign a_val[gu] = a_val_flat[gu*8 +: 8];
            assign b_val[gu] = b_val_flat[gu*8 +: 8];
            assign lane_col[gu] = lane_col_flat[gu*4 +: 4];
            assign lane_valid[gu] = lane_valid_flat[gu];
        end
    endgenerate

    // =====================================================================
    // Segment boundaries and output-column metadata.
    // =====================================================================
    logic [N_MUL_ROW-2:0] cut_comb;
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
    logic [N_MUL_ROW-1:0] lane_valid_dly [DLY_CUT];
    integer dc;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (dc = 0; dc < DLY_CUT; dc = dc + 1) begin
                cut_dly[dc]       <= '0;
                lane_valid_dly[dc] <= '0;
            end
        end else if (en) begin
            cut_dly[0]        <= cut_comb;
            lane_valid_dly[0] <= lane_valid_flat;
            for (dc = 1; dc < DLY_CUT; dc = dc + 1) cut_dly[dc] <= cut_dly[dc-1];
            for (dc = 1; dc < DLY_CUT; dc = dc + 1) lane_valid_dly[dc] <= lane_valid_dly[dc-1];
        end
    end
    wire [N_MUL_ROW-2:0] cut_aligned = cut_dly[DLY_CUT-1];
    wire [N_MUL_ROW-1:0] lane_valid_aligned = lane_valid_dly[DLY_CUT-1];

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

    logic        [N_BANK_LBUF-1:0]                   wr_valid;
    logic signed [N_BANK_LBUF-1:0][ACC_W-1:0]        wr_sum;
    logic        [N_BANK_LBUF-1:0][LOCAL_BUF_AW-1:0] wr_addr;

    generate
        if (BUCKET_REDUCE) begin : g_bucket_reduce
            logic signed [ACC_W-1:0] sum0_comb, sum1_comb, sum2_comb, sum3_comb;
            logic                    valid0_comb, valid1_comb, valid2_comb, valid3_comb;
            logic [CW-1:0]           col0_comb, col1_comb, col2_comb, col3_comb;
            logic [1:0] bucket;
            integer li_c;

            always_comb begin
                bucket = 2'd0;
                sum0_comb = '0; sum1_comb = '0; sum2_comb = '0; sum3_comb = '0;
                valid0_comb = 1'b0; valid1_comb = 1'b0; valid2_comb = 1'b0; valid3_comb = 1'b0;
                col0_comb = '0; col1_comb = '0; col2_comb = '0; col3_comb = '0;

                for (li_c = 0; li_c < N_MUL_ROW; li_c = li_c + 1) begin
                    if (lane_valid_aligned[li_c]) begin
                        bucket = off_dly[DLY_CUT-1][li_c*CW +: 2];
                        unique case (bucket)
                            2'd0: begin
                                sum0_comb   = sum0_comb + {{(ACC_W-PROD_W){partials[li_c][PROD_W-1]}}, partials[li_c]};
                                valid0_comb = 1'b1;
                                col0_comb   = off_dly[DLY_CUT-1][li_c*CW +: CW];
                            end
                            2'd1: begin
                                sum1_comb   = sum1_comb + {{(ACC_W-PROD_W){partials[li_c][PROD_W-1]}}, partials[li_c]};
                                valid1_comb = 1'b1;
                                col1_comb   = off_dly[DLY_CUT-1][li_c*CW +: CW];
                            end
                            2'd2: begin
                                sum2_comb   = sum2_comb + {{(ACC_W-PROD_W){partials[li_c][PROD_W-1]}}, partials[li_c]};
                                valid2_comb = 1'b1;
                                col2_comb   = off_dly[DLY_CUT-1][li_c*CW +: CW];
                            end
                            default: begin
                                sum3_comb   = sum3_comb + {{(ACC_W-PROD_W){partials[li_c][PROD_W-1]}}, partials[li_c]};
                                valid3_comb = 1'b1;
                                col3_comb   = off_dly[DLY_CUT-1][li_c*CW +: CW];
                            end
                        endcase
                    end
                end
            end

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    wr_valid <= '0;
                    wr_sum   <= '0;
                    wr_addr  <= '0;
                end else if (en) begin
                    wr_valid[0] <= valid0_comb;
                    wr_valid[1] <= valid1_comb;
                    wr_valid[2] <= valid2_comb;
                    wr_valid[3] <= valid3_comb;
                    wr_sum[0]   <= sum0_comb;
                    wr_sum[1]   <= sum1_comb;
                    wr_sum[2]   <= sum2_comb;
                    wr_sum[3]   <= sum3_comb;
                    wr_addr[0]  <= cnb_dly[DLY_CUT-1] + {{(LOCAL_BUF_AW-CW){1'b0}}, col0_comb};
                    wr_addr[1]  <= cnb_dly[DLY_CUT-1] + {{(LOCAL_BUF_AW-CW){1'b0}}, col1_comb};
                    wr_addr[2]  <= cnb_dly[DLY_CUT-1] + {{(LOCAL_BUF_AW-CW){1'b0}}, col2_comb};
                    wr_addr[3]  <= cnb_dly[DLY_CUT-1] + {{(LOCAL_BUF_AW-CW){1'b0}}, col3_comb};
                end
            end
        end else begin : g_tree_reduce
            // =================================================================
            // General segmented reduction, kept for debug/reference builds.
            // =================================================================
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

            logic                    ts_v    [N_MUL_ROW];
            logic signed [ACC_W-1:0] ts_sum  [N_MUL_ROW];
            logic [LOCAL_BUF_AW-1:0] ts_addr [N_MUL_ROW];
            genvar gt;
            for (gt = 0; gt < N_MUL_ROW; gt = gt + 1) begin : g_un_tree
                assign ts_v[gt]   = tree_valid_pos[gt];
                assign ts_sum[gt] = tree_sums[gt];
                assign ts_addr[gt] = cur_n_base_aligned
                                   + {{(LOCAL_BUF_AW-CW){1'b0}}, off_aligned[gt*CW +: CW]};
            end

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

            for (gt = 0; gt < N_BANK_LBUF; gt = gt + 1) begin : g_pack
                assign wr_valid[gt] = wr_v_u[gt];
                assign wr_sum[gt]   = wr_sum_u[gt];
                assign wr_addr[gt]  = wr_addr_u[gt];
            end
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
