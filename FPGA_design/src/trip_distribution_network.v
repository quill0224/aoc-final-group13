// Small crossbar-style A/B distribution network for TrIP MVP.
//
// Uses MFIU metadata to pick fixed-slot A[row][k] and B[col][k] values for
// each multiplier lane. This is a proof-of-concept replacement for the paper's
// Benes distribution networks.

module trip_distribution_network #(
    parameter NUM_ROWS   = 2,
    parameter NUM_COLS   = 2,
    parameter K_BITS     = 4,
    parameter LANES      = 4,
    parameter DATA_WIDTH = 16,
    // derived
    parameter ROW_IDX_W  = (NUM_ROWS > 1) ? $clog2(NUM_ROWS) : 1,
    parameter COL_IDX_W  = (NUM_COLS > 1) ? $clog2(NUM_COLS) : 1,
    parameter K_IDX_W    = (K_BITS   > 1) ? $clog2(K_BITS)   : 1
) (
    input  wire [NUM_ROWS*K_BITS*DATA_WIDTH-1:0] a_values_i,
    input  wire [NUM_COLS*K_BITS*DATA_WIDTH-1:0] b_values_i,

    input  wire [LANES-1:0]                       lane_valid_i,
    input  wire [LANES*ROW_IDX_W-1:0]             a_row_sel_i,
    input  wire [LANES*COL_IDX_W-1:0]             b_col_sel_i,
    input  wire [LANES*K_IDX_W-1:0]               k_sel_i,

    output wire [LANES-1:0]                       lane_valid_o,
    output wire [LANES*DATA_WIDTH-1:0]            lane_a_o,
    output wire [LANES*DATA_WIDTH-1:0]            lane_b_o
);

    genvar gl;
    generate
        for (gl = 0; gl < LANES; gl = gl + 1) begin : gen_dist
            wire [ROW_IDX_W-1:0] row_sel;
            wire [COL_IDX_W-1:0] col_sel;
            wire [K_IDX_W-1:0]   k_sel;
            wire [31:0]          row_sel_ext;
            wire [31:0]          col_sel_ext;
            wire [31:0]          k_sel_ext;
            wire [31:0]          a_slot;
            wire [31:0]          b_slot;

            assign row_sel = a_row_sel_i[gl*ROW_IDX_W +: ROW_IDX_W];
            assign col_sel = b_col_sel_i[gl*COL_IDX_W +: COL_IDX_W];
            assign k_sel   = k_sel_i    [gl*K_IDX_W   +: K_IDX_W];
            assign row_sel_ext = {{(32-ROW_IDX_W){1'b0}}, row_sel};
            assign col_sel_ext = {{(32-COL_IDX_W){1'b0}}, col_sel};
            assign k_sel_ext   = {{(32-K_IDX_W){1'b0}}, k_sel};
            assign a_slot  = (row_sel_ext * K_BITS) + k_sel_ext;
            assign b_slot  = (col_sel_ext * K_BITS) + k_sel_ext;

            assign lane_valid_o[gl] = lane_valid_i[gl];
            assign lane_a_o[gl*DATA_WIDTH +: DATA_WIDTH] =
                lane_valid_i[gl] ? a_values_i[a_slot*DATA_WIDTH +: DATA_WIDTH] : {DATA_WIDTH{1'b0}};
            assign lane_b_o[gl*DATA_WIDTH +: DATA_WIDTH] =
                lane_valid_i[gl] ? b_values_i[b_slot*DATA_WIDTH +: DATA_WIDTH] : {DATA_WIDTH{1'b0}};
        end
    endgenerate

endmodule
