// =============================================================================
// dist_net_row_trip.sv — Per-PE-row TrIP multi-fiber A/B Distribution network
// =============================================================================
// Owner: NoC(QuillQ + Huang Yan-Hsin)
// Paper : Trapezoid (ISCA'24) Fig 6 "A/B Distribution", multi-fiber TrIP path
//
// === What this file does (integrated version, aligned to paper multi-fiber) ===
// Take the effectual (row,col,k) indices computed by MFIU and gather the
// matching a / b values from the fiber value buffer to the right multiplier lane:
//
//     a_lane[l] = a_values[ a_row_sel[l] ][ k_sel[l] ]
//     b_lane[l] = b_values[ b_col_sel[l] ][ k_sel[l] ]
//
// This is a "2D gather": each lane fetches by two coords (fiber, k), matching the
// 4x4 fiber packing - one row of 16 lanes can serve multiple outputs (r,c) at once.
//
// === Difference from the Dense version dist_net_row.sv ===
//   Dense   : single effectual_idx, 1D gather  out[m]=in[idx[m]] (a/b share idx)
//   TrIP    : three sels (row/col/k), 2D gather (a uses row, b uses col, k shared)
//   -> Both modules coexist: Dense IP uses dist_net_row, TrIP uses this file
//      (selected by dataflow_ctrl)
//
// === Origin ===
// Algorithm ported from the FPGA MVP trip_distribution_network.v
//   (original: pure combinational, Verilog-2001, raw params, LANES=4 2x2 MVP)
// Integration rewrite in this file:
//   (1) SystemVerilog + import trapezoid_pkg (single source for types/params)
//   (2) scaled to spec: N_A_FIBER=4 / N_B_FIBER=4 / BITMASK_W=16 / LANES=16
//   (3) add 1 output register stage (DIST_STAGES=1) + in_valid->out_valid handshake
//       -> aligns with the pe_row pipeline (see trapezoid_pkg PE_ROW_STAGES)
//   (4) iverilog variable-index limit on packed arrays -> flatten to unpacked first
//
// === Alignment with the MFIU interface (conversion for pe_row wiring, Iris wrap) ===
// MFIU outputs a flat packed bus; this file inputs SV multi-dim packed arrays:
//   mfiu a_row_sel_o[LANES*ROW_IDX_W-1:0]  ->  here a_row_sel[LANES][ROW_IDX_W]
//   mfiu b_col_sel_o[LANES*COL_IDX_W-1:0]  ->  here b_col_sel[LANES][COL_IDX_W]
//   mfiu k_sel_o    [LANES*K_IDX_W-1:0]    ->  here k_sel    [LANES][K_IDX_W]
//   mfiu lane_valid_o[LANES-1:0]           ->  here lane_valid[LANES]
// (bit-for-bit identical, only the packing shape differs; wire lane l via [l*W +: W])
// =============================================================================

module dist_net_row_trip
    import trapezoid_pkg::*;
#(
    parameter int NUM_A_FIBER = N_A_FIBER,    // 4  (A rows packed at once)
    parameter int NUM_B_FIBER = N_B_FIBER,    // 4  (B cols streamed at once)
    parameter int K_SLOTS     = BITMASK_W,    // 16 (k slots per fiber)
    parameter int LANES       = N_MUL_ROW,    // 16 (= multipliers in one PE row)
    // -- derived (do not override externally) --
    parameter int ROW_IDX_W   = (NUM_A_FIBER > 1) ? $clog2(NUM_A_FIBER) : 1,  // 2
    parameter int COL_IDX_W   = (NUM_B_FIBER > 1) ? $clog2(NUM_B_FIBER) : 1,  // 2
    parameter int K_IDX_W     = (K_SLOTS     > 1) ? $clog2(K_SLOTS)     : 1,  // 4
    parameter int A_DEPTH     = NUM_A_FIBER * K_SLOTS,                        // 64
    parameter int B_DEPTH     = NUM_B_FIBER * K_SLOTS                         // 64
)(
    input  logic clk,
    input  logic rst_n,
    input  logic en,
    input  logic in_valid,

    // -- fiber value buffer (2D: [fiber][k]) --
    input  logic signed [NUM_A_FIBER-1:0][K_SLOTS-1:0][DATA_W-1:0] a_values,
    input  logic signed [NUM_B_FIBER-1:0][K_SLOTS-1:0][DATA_W-1:0] b_values,

    // -- per-lane routing metadata from MFIU --
    input  logic [LANES-1:0]                  lane_valid,
    input  logic [LANES-1:0][ROW_IDX_W-1:0]   a_row_sel,
    input  logic [LANES-1:0][COL_IDX_W-1:0]   b_col_sel,
    input  logic [LANES-1:0][K_IDX_W-1:0]     k_sel,

    // -- gathered a/b to the multiplier (registered) --
    output logic signed [LANES-1:0][DATA_W-1:0] a_lane_out,
    output logic signed [LANES-1:0][DATA_W-1:0] b_lane_out,
    output logic [LANES-1:0]                     lane_valid_out,
    output logic                                 out_valid
);

    // ========================================================================
    // 0) Flatten packed -> unpacked flat array
    //    iverilog disallows variable index on packed array dims; unpacked is OK.
    //    a_values[fiber][k]  ->  a_flat[ fiber*K_SLOTS + k ]
    // ========================================================================
    logic signed [DATA_W-1:0] a_flat [A_DEPTH];   // 64 a values
    logic signed [DATA_W-1:0] b_flat [B_DEPTH];   // 64 b values

    genvar gr, gk;
    generate
        for (gr = 0; gr < NUM_A_FIBER; gr = gr + 1) begin : g_a_fiber
            for (gk = 0; gk < K_SLOTS; gk = gk + 1) begin : g_a_k
                assign a_flat[gr*K_SLOTS + gk] = a_values[gr][gk];
            end
        end
        for (gr = 0; gr < NUM_B_FIBER; gr = gr + 1) begin : g_b_fiber
            for (gk = 0; gk < K_SLOTS; gk = gk + 1) begin : g_b_k
                assign b_flat[gr*K_SLOTS + gk] = b_values[gr][gk];
            end
        end
    endgenerate

    // flatten metadata to unpacked too (also for variable-index safety)
    logic [ROW_IDX_W-1:0] row_u [LANES];
    logic [COL_IDX_W-1:0] col_u [LANES];
    logic [K_IDX_W-1:0]   k_u   [LANES];
    logic                 vld_u [LANES];

    genvar gl;
    generate
        for (gl = 0; gl < LANES; gl = gl + 1) begin : g_meta_unpack
            assign row_u[gl] = a_row_sel[gl];
            assign col_u[gl] = b_col_sel[gl];
            assign k_u[gl]   = k_sel[gl];
            assign vld_u[gl] = lane_valid[gl];
        end
    endgenerate

    // ========================================================================
    // 1) Combinational 2D gather (= one row of 16 64-to-1 muxes, one set each a/b)
    //    a_slot = row*K_SLOTS + k  (flatten (fiber,k) to a flat offset)
    //    invalid lane outputs 0 -> downstream multiplier yields 0, no reduction pollution
    //    broadcast supported natively: multiple lanes may point to the same slot (TrGT stretch)
    // ========================================================================
    logic signed [DATA_W-1:0] a_lane_c [LANES];
    logic signed [DATA_W-1:0] b_lane_c [LANES];

    integer l;
    always_comb begin
        for (l = 0; l < LANES; l = l + 1) begin
            if (vld_u[l]) begin
                a_lane_c[l] = a_flat[ row_u[l]*K_SLOTS + k_u[l] ];
                b_lane_c[l] = b_flat[ col_u[l]*K_SLOTS + k_u[l] ];
            end else begin
                a_lane_c[l] = '0;
                b_lane_c[l] = '0;
            end
        end
    end

    // ========================================================================
    // 2) Output register (DIST_STAGES = 1) + valid pipeline
    //    aligns with trapezoid_pkg::DIST_STAGES; breaks the long 64-to-1 mux combinational path
    // ========================================================================
    logic signed [DATA_W-1:0] a_lane_q [LANES];
    logic signed [DATA_W-1:0] b_lane_q [LANES];
    logic [LANES-1:0]         vld_q;

    integer r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (r = 0; r < LANES; r = r + 1) begin
                a_lane_q[r] <= '0;
                b_lane_q[r] <= '0;
            end
            vld_q     <= '0;
            out_valid <= 1'b0;
        end else if (en) begin
            for (r = 0; r < LANES; r = r + 1) begin
                a_lane_q[r] <= a_lane_c[r];
                b_lane_q[r] <= b_lane_c[r];
            end
            vld_q     <= lane_valid;   // register the post-gather per-lane valid in step
            out_valid <= in_valid;
        end
    end

    // unpacked -> packed output port
    genvar go;
    generate
        for (go = 0; go < LANES; go = go + 1) begin : g_pack_out
            assign a_lane_out[go]     = a_lane_q[go];
            assign b_lane_out[go]     = b_lane_q[go];
            assign lane_valid_out[go] = vld_q[go];
        end
    endgenerate

    // synthesis-time sanity: this file assumes DIST_STAGES=1; if pkg changes, add stages here
    initial begin
        if (DIST_STAGES != 1)
            $warning("dist_net_row_trip: DIST_STAGES=%0d but this module hard-codes 1 register stage", DIST_STAGES);
    end

endmodule
