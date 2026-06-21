// =============================================================================
// pe_row_full.sv — full PE row (multi-fiber TrIP path + B-fiber grouping)
// =============================================================================
// One PE row datapath. A is row-stationary (loaded once on a_load_valid, then
// held); B is streaming (latched on in_valid). A/B are multi-fiber
// (N_A_FIBER x N_B_FIBER fibers, BITMASK_W slots each). Dense is the fiber0-only
// special case (other fibers mask=0 -> identity), no separate branch.
//
// Path: mfiu_adapter_mf -> dist_net_row_trip -> mac x16 -> reduction_tree
//       -> 16->4 compaction -> local_buffer_row.
//
// Reduction grouping (generated here from MFIU per-lane metadata):
//   cut_after[i] = lane_valid[i] & lane_valid[i+1] & (b_col_sel[i]!=b_col_sel[i+1])
//                  = a cut between lane i and lane i+1 when adjacent valid lanes
//                    belong to different B fibers.
//   out_addr_by_lane[l] = cur_n + b_col_sel[l] (different B fiber -> different
//                  output column). Invalid tail lanes inherit the last valid
//                  lane's output address, so a group end landing on an invalid
//                  tail still gets the correct column.
//   Group identity uses b_col_sel only (A-fiber -> output-row is a later stage;
//   local_buffer is one PE row, address = column).
//
// Pipeline / timing alignment:
//   S1     A load+hold / B stream latch
//   S2-S4  mfiu_adapter_mf (MFIU_STAGES=3) -> lane_valid/a_row_sel/b_col_sel/k_sel
//   S5     dist_net_row_trip (2D gather; invalid lane -> 0)
//   S6     mac_unit x16
//   S7     reduction_tree_radix16 (cut_after segments)
//   S8a/b  16->4 compaction (per-group out_addr) + local_buffer_row
//   Grouping metadata is built combinationally at the MFIU-output cycle, then
//   delayed to its consumer:
//     cut_after          by DLY_CUT  = DIST+MUL       -> tree input (with partials)
//     out_addr/has_match by DLY_ADDR = DIST+MUL+TREE  -> S8a
//     cur_n base         by DLY_FP                    -> S8a (same as first_pass)
//
// no-match: when lane_valid is all 0, acc_en is gated by has_match so no zero
//           group is written to the buffer.
// overflow: effectual > 16 lanes is not replayed here; sim warning only.
// =============================================================================

module pe_row_full
    import trapezoid_pkg::*;
(
    input  logic                                              clk,
    input  logic                                              rst_n,

    // ── control ──
    input  logic [1:0]                                        dataflow_sel,
    input  logic                                              in_valid,     // B stream valid
    input  logic [LOCAL_BUF_AW-1:0]                           cur_n,
    input  logic                                              first_pass,
    input  logic                                              dump_en,
    input  logic [LOCAL_BUF_AW-1:0]                           dump_addr,

    // ── A: row-stationary, multi-fiber ──
    input  logic                                              a_load_valid,
    input  logic signed [N_A_FIBER-1:0][BITMASK_W-1:0][DATA_W-1:0] a_vec,
    input  logic        [N_A_FIBER-1:0][BITMASK_W-1:0]             a_bitmask,
    input  logic                                              a_clear,

    // ── B: stream, multi-fiber ──
    input  logic signed [N_B_FIBER-1:0][BITMASK_W-1:0][DATA_W-1:0] b_vec_in,
    input  logic        [N_B_FIBER-1:0][BITMASK_W-1:0]             b_bitmask_in,

    // ── B forwarding to next row (multi-fiber) ──
    output logic signed [N_B_FIBER-1:0][BITMASK_W-1:0][DATA_W-1:0] b_vec_out,
    output logic        [N_B_FIBER-1:0][BITMASK_W-1:0]             b_bitmask_out,
    output logic                                              b_valid_out,

    // ── C output ──
    output logic                                              c_valid,
    output logic signed [ACC_W-1:0]                           c_out
);

    // internal pipeline advances freely
    wire en = 1'b1;

    // delay depths (align control signals to the data path)
    localparam int DLY_AB   = MFIU_STAGES;                                             // 3: A/B values -> MFIU output
    localparam int DLY_CUT  = DIST_STAGES + MUL_STAGES;                                // 2: MFIU out -> tree input
    localparam int DLY_ADDR = DIST_STAGES + MUL_STAGES + TREE_STAGES;                  // 3: MFIU out -> S8a
    localparam int DLY_FP   = 1 + MFIU_STAGES + DIST_STAGES + MUL_STAGES + TREE_STAGES;// 7: raw input -> buffer write

    // =====================================================================
    // S1: input latch — A row-stationary (load+hold), B stream
    // =====================================================================
    logic signed [N_A_FIBER-1:0][BITMASK_W-1:0][DATA_W-1:0] a_q;
    logic        [N_A_FIBER-1:0][BITMASK_W-1:0]             a_bm_q;
    logic signed [N_B_FIBER-1:0][BITMASK_W-1:0][DATA_W-1:0] b_q;
    logic        [N_B_FIBER-1:0][BITMASK_W-1:0]             b_bm_q;
    logic                                                   v_q;
    logic                                                   a_loaded;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_q <= '0; a_bm_q <= '0; b_q <= '0; b_bm_q <= '0;
            v_q <= 1'b0; a_loaded <= 1'b0;
        end else if (en) begin
            if (a_load_valid) begin
                a_q      <= a_vec;
                a_bm_q   <= a_bitmask;
                a_loaded <= 1'b1;
            end else if (a_clear) begin
                a_loaded <= 1'b0;
            end
            if (in_valid) begin
                b_q    <= b_vec_in;
                b_bm_q <= b_bitmask_in;
            end
            v_q <= a_loaded & in_valid;   // compute valid (A loaded AND B stream valid)
        end
    end

    // ── flatten 2D masks → flat bus for mfiu_adapter_mf (fiber r at [r*BITMASK_W +: BITMASK_W]) ──
    logic [N_A_FIBER*BITMASK_W-1:0] a_bm_flat;
    logic [N_B_FIBER*BITMASK_W-1:0] b_bm_flat;
    genvar gff;
    generate
        for (gff = 0; gff < N_A_FIBER; gff = gff + 1) begin : g_a_flat
            assign a_bm_flat[gff*BITMASK_W +: BITMASK_W] = a_bm_q[gff];
        end
        for (gff = 0; gff < N_B_FIBER; gff = gff + 1) begin : g_b_flat
            assign b_bm_flat[gff*BITMASK_W +: BITMASK_W] = b_bm_q[gff];
        end
    endgenerate

    // =====================================================================
    // S2-S4: MFIU (mfiu_adapter_mf, 4×4 multi-fiber)
    // =====================================================================
    logic [N_MUL_ROW-1:0]                    mf_lane_valid;
    logic [N_MUL_ROW-1:0][A_FIBER_IDX_W-1:0] mf_a_row_sel;
    logic [N_MUL_ROW-1:0][B_FIBER_IDX_W-1:0] mf_b_col_sel;
    logic [N_MUL_ROW-1:0][K_IDX_W-1:0]       mf_k_sel;
    logic [LANE_COUNT_W-1:0]                 mf_match_count;
    logic                                    mf_overflow;
    logic                                    mf_meta_valid;

    mfiu_adapter_mf u_mfiu (
        .clk         (clk),
        .rst_n       (rst_n),
        .en          (en),
        .in_valid    (v_q),
        .a_bitmask   (a_bm_flat),
        .b_bitmask   (b_bm_flat),
        .lane_valid  (mf_lane_valid),
        .a_row_sel   (mf_a_row_sel),
        .b_col_sel   (mf_b_col_sel),
        .k_sel       (mf_k_sel),
        .match_count (mf_match_count),
        .overflow    (mf_overflow),
        .meta_valid  (mf_meta_valid)
    );

    // ── delay A/B values by MFIU_STAGES to align with MFIU metadata ──
    logic signed [N_A_FIBER-1:0][BITMASK_W-1:0][DATA_W-1:0] a_dly [DLY_AB];
    logic signed [N_B_FIBER-1:0][BITMASK_W-1:0][DATA_W-1:0] b_dly [DLY_AB];
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
    wire signed [N_A_FIBER-1:0][BITMASK_W-1:0][DATA_W-1:0] a_aligned = a_dly[DLY_AB-1];
    wire signed [N_B_FIBER-1:0][BITMASK_W-1:0][DATA_W-1:0] b_aligned = b_dly[DLY_AB-1];

    // =====================================================================
    // Group metadata generation (combinational, at MFIU output cycle)
    //   B-fiber grouping: group identity = b_col_sel; out column = cur_n + b_col_sel
    // =====================================================================
    // unpack MFIU metadata for indexing
    logic [B_FIBER_IDX_W-1:0] bcol_u [N_MUL_ROW];
    logic                     lv_u   [N_MUL_ROW];
    genvar gu;
    generate
        for (gu = 0; gu < N_MUL_ROW; gu = gu + 1) begin : g_meta_u
            assign bcol_u[gu] = mf_b_col_sel[gu];
            assign lv_u[gu]   = mf_lane_valid[gu];
        end
    endgenerate

    // cut_after[i]: adjacent valid lanes of different B fiber → cut between i and i+1
    logic [N_MUL_ROW-2:0] cut_comb;
    generate
        for (gu = 0; gu < N_MUL_ROW-1; gu = gu + 1) begin : g_cut
            assign cut_comb[gu] = lv_u[gu] & lv_u[gu+1] & (bcol_u[gu] != bcol_u[gu+1]);
        end
    endgenerate

    // per-lane output-column offset (= b_col_sel); invalid tail inherits last valid offset
    logic [B_FIBER_IDX_W-1:0] off_u [N_MUL_ROW];
    logic [B_FIBER_IDX_W-1:0] last_off;
    integer io;
    always_comb begin
        last_off = '0;
        for (io = 0; io < N_MUL_ROW; io = io + 1) begin
            if (lv_u[io]) begin
                off_u[io] = bcol_u[io];
                last_off  = bcol_u[io];
            end else begin
                off_u[io] = last_off;
            end
        end
    end
    // pack offset → flat bus for the delay line
    logic [N_MUL_ROW*B_FIBER_IDX_W-1:0] off_flat;
    generate
        for (gu = 0; gu < N_MUL_ROW; gu = gu + 1) begin : g_off_pack
            assign off_flat[gu*B_FIBER_IDX_W +: B_FIBER_IDX_W] = off_u[gu];
        end
    endgenerate

    wire has_match = |mf_lane_valid;

    // ── delay cut_after by DLY_CUT to align with partials entering tree ──
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

    // ── delay per-lane offset + has_match by DLY_ADDR to align with S8a ──
    logic [N_MUL_ROW*B_FIBER_IDX_W-1:0] off_dly [DLY_ADDR];
    logic                               hm_dly  [DLY_ADDR];
    integer doa;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (doa = 0; doa < DLY_ADDR; doa = doa + 1) begin off_dly[doa] <= '0; hm_dly[doa] <= 1'b0; end
        end else if (en) begin
            off_dly[0] <= off_flat; hm_dly[0] <= has_match;
            for (doa = 1; doa < DLY_ADDR; doa = doa + 1) begin
                off_dly[doa] <= off_dly[doa-1]; hm_dly[doa] <= hm_dly[doa-1];
            end
        end
    end
    wire [N_MUL_ROW*B_FIBER_IDX_W-1:0] off_aligned       = off_dly[DLY_ADDR-1];
    wire                               has_match_aligned = hm_dly[DLY_ADDR-1];

    // ── delay cur_n base by DLY_FP to align with S8a (= buffer write) ──
    logic [LOCAL_BUF_AW-1:0] curn_dly [DLY_FP];
    integer dcn;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (dcn = 0; dcn < DLY_FP; dcn = dcn + 1) curn_dly[dcn] <= '0;
        end else if (en) begin
            curn_dly[0] <= cur_n;
            for (dcn = 1; dcn < DLY_FP; dcn = dcn + 1) curn_dly[dcn] <= curn_dly[dcn-1];
        end
    end
    wire [LOCAL_BUF_AW-1:0] cur_n_aligned = curn_dly[DLY_FP-1];

    // ── delay first_pass by DLY_FP to align with buffer write ──
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
    // S5: A/B distribution (dist_net_row_trip, 2D gather; invalid lane -> 0)
    // =====================================================================
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] dist_a, dist_b;
    logic        [N_MUL_ROW-1:0]             dist_lane_valid;
    logic                                    dist_vld;

    dist_net_row_trip u_dist (
        .clk            (clk),
        .rst_n          (rst_n),
        .en             (en),
        .in_valid       (mf_meta_valid),
        .a_values       (a_aligned),
        .b_values       (b_aligned),
        .lane_valid     (mf_lane_valid),
        .a_row_sel      (mf_a_row_sel),
        .b_col_sel      (mf_b_col_sel),
        .k_sel          (mf_k_sel),
        .a_lane_out     (dist_a),
        .b_lane_out     (dist_b),
        .lane_valid_out (dist_lane_valid),
        .out_valid      (dist_vld)
    );

    // =====================================================================
    // S6: Mul × 16 (mac_unit) — invalid lanes already zeroed by dist
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

    // =====================================================================
    // S7: reduction tree — cut_after from B-fiber grouping
    // =====================================================================
    logic signed [N_MUL_ROW-1:0][ACC_W-1:0]  tree_sums;
    logic        [N_MUL_ROW-1:0]             tree_valid_pos;

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

    // =====================================================================
    // S8a: 16→4 compaction — per-group out_addr = cur_n + b_col_sel offset
    // =====================================================================
    logic                    ts_v    [N_MUL_ROW];
    logic signed [ACC_W-1:0] ts_sum  [N_MUL_ROW];
    logic [LOCAL_BUF_AW-1:0] ts_addr [N_MUL_ROW];
    genvar gt;
    generate
        for (gt = 0; gt < N_MUL_ROW; gt = gt + 1) begin : g_un_tree
            assign ts_v[gt]    = tree_valid_pos[gt];
            assign ts_sum[gt]  = tree_sums[gt];
            assign ts_addr[gt] = cur_n_aligned + off_aligned[gt*B_FIBER_IDX_W +: B_FIBER_IDX_W];
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
    // S8b: Local Buffer — acc_en gated by has_match (no write on no-match)
    // =====================================================================
    wire acc_en = tree_out_vld & has_match_aligned;

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

    // =====================================================================
    // B forwarding: delay b_vec_in by 1 cycle to next row (multi-fiber)
    // =====================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_vec_out <= '0; b_bitmask_out <= '0; b_valid_out <= 1'b0;
        end else if (en) begin
            b_vec_out <= b_vec_in; b_bitmask_out <= b_bitmask_in; b_valid_out <= in_valid;
        end
    end

    // =====================================================================
    // overflow: no replay this stage — catch in sim, do not drop silently
    // =====================================================================
    // synthesis translate_off
    always @(posedge clk) if (rst_n && mf_meta_valid && mf_overflow)
        $display("[WARN] %0t pe_row_full: MFIU overflow (effectual MACs > %0d lanes); no replay -> extra effectuals dropped",
                 $time, N_MUL_ROW);
    // synthesis translate_on

    // unused this stage: dataflow_sel (no Dense/TrIP branch), match_count, per-lane dist valid
    wire _unused = &{1'b0, dataflow_sel, mf_match_count, dist_lane_valid};

endmodule
