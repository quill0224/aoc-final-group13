// A/B distribution network.
//
// Direct mode uses the fixed lane layout:
//   lane = row*(NUM_COLS*K_BITS) + col*K_BITS + k
//
// Packed mode uses explicit row/column/k metadata from the packed MFIU.

module trip_distribution_network #(
    parameter NUM_ROWS   = 2,
    parameter NUM_COLS   = 2,
    parameter K_BITS     = 4,
    parameter LANES      = 4,
    parameter DATA_WIDTH = 16,
    parameter PACKED_MODE = 0,
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
        if (PACKED_MODE == 0) begin : GEN_DIRECT
            for (gl = 0; gl < LANES; gl = gl + 1) begin : GEN_DIST
                localparam R_L = gl / (NUM_COLS * K_BITS);
                localparam C_L = (gl / K_BITS) % NUM_COLS;
                localparam K_L = gl % K_BITS;
                localparam A_SLOT = R_L * K_BITS + K_L;
                localparam B_SLOT = C_L * K_BITS + K_L;

                assign lane_valid_o[gl] = lane_valid_i[gl];
                assign lane_a_o[gl*DATA_WIDTH +: DATA_WIDTH] =
                    lane_valid_i[gl] ? a_values_i[A_SLOT*DATA_WIDTH +: DATA_WIDTH] : {DATA_WIDTH{1'b0}};
                assign lane_b_o[gl*DATA_WIDTH +: DATA_WIDTH] =
                    lane_valid_i[gl] ? b_values_i[B_SLOT*DATA_WIDTH +: DATA_WIDTH] : {DATA_WIDTH{1'b0}};
            end

            wire unused_selectors = &{1'b0, a_row_sel_i, b_col_sel_i, k_sel_i};
        end else begin : GEN_PACKED
            reg [LANES-1:0] lane_valid_r;
            reg [LANES*DATA_WIDTH-1:0] lane_a_r;
            reg [LANES*DATA_WIDTH-1:0] lane_b_r;
            integer l_i;
            integer a_slot;
            integer b_slot;

            always @(*) begin
                lane_valid_r = lane_valid_i;
                lane_a_r = {(LANES*DATA_WIDTH){1'b0}};
                lane_b_r = {(LANES*DATA_WIDTH){1'b0}};
                a_slot = 0;
                b_slot = 0;

                for (l_i = 0; l_i < LANES; l_i = l_i + 1) begin
                    if (lane_valid_i[l_i]) begin
                        a_slot = a_row_sel_i[l_i*ROW_IDX_W +: ROW_IDX_W] * K_BITS
                               + k_sel_i[l_i*K_IDX_W +: K_IDX_W];
                        b_slot = b_col_sel_i[l_i*COL_IDX_W +: COL_IDX_W] * K_BITS
                               + k_sel_i[l_i*K_IDX_W +: K_IDX_W];
                        lane_a_r[l_i*DATA_WIDTH +: DATA_WIDTH] =
                            a_values_i[a_slot*DATA_WIDTH +: DATA_WIDTH];
                        lane_b_r[l_i*DATA_WIDTH +: DATA_WIDTH] =
                            b_values_i[b_slot*DATA_WIDTH +: DATA_WIDTH];
                    end
                end
            end

            assign lane_valid_o = lane_valid_r;
            assign lane_a_o = lane_a_r;
            assign lane_b_o = lane_b_r;
        end
    endgenerate

endmodule
