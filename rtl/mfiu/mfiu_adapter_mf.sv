// =============================================================================
// mfiu_adapter_mf.sv - Multi-Fiber MFIU adapter (4x4 packing)
// =============================================================================
// Owner: NoC(QuillQ) - multi-fiber MFIU wrapper; feeds dist_net_row_trip
// Paper: Trapezoid (ISCA'24) Fig 11/12, Multi-Fiber Intersection Unit
//
// === Difference vs Iris single-fiber mfiu_adapter.sv ===
//   Single-fiber: configures the mfiu core as 1x1, emits one effectual_idx
//   This (multi-fiber): configures the core as N_A_FIBER x N_B_FIBER (4x4), emits three
//                buses a_row_sel / b_col_sel / k_sel + lane_valid, wiring straight into
//                dist_net_row_trip (2D gather).
//   -> Both versions coexist: dataflow_ctrl / integration picks which to use.
//
// === What it does ===
//   1. Instantiate the mfiu.v core (NUM_ROWS=4, NUM_COLS=4, K_BITS=16, LANES=16)
//      -> scan 4x4x16 candidates, pack effectual (r,c,k) into 16 lanes, assert flag on overflow
//   2. Convert the core's flat bus outputs into the multi-dim ports dist_net_row_trip needs
//   3. Delay MFIU_STAGES cycles to align with the pe_row datapath
//
// === Upstream requirement (2D feed) ===
//   a_bitmask / b_bitmask are now "4 fibers x 16 bit each" = 64 bit (not a single 16).
//   pe_row / buffer must supply bitmask and value for all 4 A fibers + 4 B fibers.
//   The value lines (a_values/b_values) feed dist_net_row_trip directly.
//
// === Overflow note ===
//   One cycle's 4x4x16 candidates far exceed 16 lanes; core packs 16 full then asserts overflow_o.
//   Replay (re-issuing the unpacked remainder next cycle) is the upstream ctrl's job; this file just passes overflow through.
// =============================================================================

module mfiu_adapter_mf
    import trapezoid_pkg::*;
#(
    parameter int NUM_A_FIBER = N_A_FIBER,   // 4
    parameter int NUM_B_FIBER = N_B_FIBER,   // 4
    parameter int K_SLOTS     = BITMASK_W,   // 16
    parameter int LANES       = N_MUL_ROW,   // 16
    // -- derived --
    parameter int ROW_IDX_W = (NUM_A_FIBER > 1) ? $clog2(NUM_A_FIBER) : 1,  // 2
    parameter int COL_IDX_W = (NUM_B_FIBER > 1) ? $clog2(NUM_B_FIBER) : 1,  // 2
    parameter int K_IDX_W   = (K_SLOTS     > 1) ? $clog2(K_SLOTS)     : 1,  // 4
    parameter int CNT_W     = $clog2(LANES + 1)                             // 5
)(
    input  logic clk,
    input  logic rst_n,
    input  logic en,
    input  logic in_valid,

    // -- bitmask of 4 fibers, K_SLOTS bit each (fed by upstream) --
    input  logic [NUM_A_FIBER*K_SLOTS-1:0] a_bitmask,
    input  logic [NUM_B_FIBER*K_SLOTS-1:0] b_bitmask,

    // -- multi-dim routing metadata for dist_net_row_trip (registered) --
    output logic [LANES-1:0]                  lane_valid,
    output logic [LANES-1:0][ROW_IDX_W-1:0]   a_row_sel,
    output logic [LANES-1:0][COL_IDX_W-1:0]   b_col_sel,
    output logic [LANES-1:0][K_IDX_W-1:0]     k_sel,
    output logic [CNT_W-1:0]                  match_count,
    output logic                              overflow,
    output logic                              meta_valid
);

    // -- intersection core: mfiu.v, configured as 4x4 x K_SLOTS --
    logic [LANES-1:0]           core_vld;
    logic [LANES*ROW_IDX_W-1:0] core_row;
    logic [LANES*COL_IDX_W-1:0] core_col;
    logic [LANES*K_IDX_W-1:0]   core_k;
    logic [CNT_W-1:0]           core_cnt;
    logic                       core_ovf;

    mfiu #(
        .NUM_ROWS (NUM_A_FIBER),
        .NUM_COLS (NUM_B_FIBER),
        .K_BITS   (K_SLOTS),
        .LANES    (LANES)
    ) u_core (
        .a_mask_i      (a_bitmask),
        .b_mask_i      (b_bitmask),
        .lane_valid_o  (core_vld),
        .a_row_sel_o   (core_row),
        .b_col_sel_o   (core_col),
        .k_sel_o       (core_k),
        .match_count_o (core_cnt),
        .overflow_o    (core_ovf)
    );

    // -- delay MFIU_STAGES cycles (align with datapath) --
    logic [LANES-1:0]           vld_pipe [MFIU_STAGES];
    logic [LANES*ROW_IDX_W-1:0] row_pipe [MFIU_STAGES];
    logic [LANES*COL_IDX_W-1:0] col_pipe [MFIU_STAGES];
    logic [LANES*K_IDX_W-1:0]   k_pipe   [MFIU_STAGES];
    logic [CNT_W-1:0]           cnt_pipe [MFIU_STAGES];
    logic                       ovf_pipe [MFIU_STAGES];
    logic [MFIU_STAGES-1:0]     mvld_pipe;

    integer s;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (s = 0; s < MFIU_STAGES; s = s + 1) begin
                vld_pipe[s] <= '0; row_pipe[s] <= '0; col_pipe[s] <= '0;
                k_pipe[s]   <= '0; cnt_pipe[s] <= '0; ovf_pipe[s] <= '0;
            end
            mvld_pipe <= '0;
        end else if (en) begin
            vld_pipe[0] <= core_vld; row_pipe[0] <= core_row; col_pipe[0] <= core_col;
            k_pipe[0]   <= core_k;   cnt_pipe[0] <= core_cnt; ovf_pipe[0] <= core_ovf;
            for (s = 1; s < MFIU_STAGES; s = s + 1) begin
                vld_pipe[s] <= vld_pipe[s-1]; row_pipe[s] <= row_pipe[s-1];
                col_pipe[s] <= col_pipe[s-1]; k_pipe[s]   <= k_pipe[s-1];
                cnt_pipe[s] <= cnt_pipe[s-1]; ovf_pipe[s] <= ovf_pipe[s-1];
            end
            mvld_pipe <= {mvld_pipe[MFIU_STAGES-2:0], in_valid};
        end
    end

    // -- flat bus -> multi-dim port (final stage) --
    genvar g;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : g_unpack
            assign a_row_sel[g] = row_pipe[MFIU_STAGES-1][g*ROW_IDX_W +: ROW_IDX_W];
            assign b_col_sel[g] = col_pipe[MFIU_STAGES-1][g*COL_IDX_W +: COL_IDX_W];
            assign k_sel[g]     = k_pipe  [MFIU_STAGES-1][g*K_IDX_W   +: K_IDX_W];
        end
    endgenerate
    assign lane_valid  = vld_pipe[MFIU_STAGES-1];
    assign match_count = cnt_pipe[MFIU_STAGES-1];
    assign overflow    = ovf_pipe[MFIU_STAGES-1];
    assign meta_valid  = mvld_pipe[MFIU_STAGES-1];

endmodule
