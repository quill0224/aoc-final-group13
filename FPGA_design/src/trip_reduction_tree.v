// trip_reduction_tree.v
//
// Direct mode keeps the timing-optimized fixed lane layout:
//   lane = row*(NUM_COLS*K_BITS) + col*K_BITS + k
//
// Packed mode gathers products by explicit row/column metadata from the
// packed MFIU.  Packed mode is functionally aligned with Trapezoid's MFIU
// routing, but needs further pipelining before it is timing competitive.

module trip_reduction_tree #(
    parameter NUM_ROWS      = 4,
    parameter NUM_COLS      = 4,
    parameter K_BITS        = 4,
    parameter LANES         = 64,
    parameter DATA_WIDTH    = 16,
    parameter PRODUCT_WIDTH = DATA_WIDTH * 2,
    parameter ACC_WIDTH     = PRODUCT_WIDTH + $clog2(LANES + 1),
    parameter SIGNED_DATA   = 0,
    parameter PACKED_MODE   = 0,
    // derived
    parameter ROW_IDX_W     = (NUM_ROWS > 1) ? $clog2(NUM_ROWS) : 1,
    parameter COL_IDX_W     = (NUM_COLS > 1) ? $clog2(NUM_COLS) : 1,
    parameter NUM_OUTPUTS   = NUM_ROWS * NUM_COLS,
    parameter LOG2_K_BITS   = $clog2(K_BITS)
) (
    input  wire                                    clk,
    input  wire                                    reset,
    input  wire [LANES-1:0]                       lane_valid_i,
    input  wire [LANES*ROW_IDX_W-1:0]             a_row_sel_i,
    input  wire [LANES*COL_IDX_W-1:0]             b_col_sel_i,
    input  wire [LANES*PRODUCT_WIDTH-1:0]         lane_product_i,
    input  wire [NUM_OUTPUTS-1:0]                 out_enable_i,

    output wire [NUM_OUTPUTS-1:0]                 out_valid_o,
    output wire [NUM_OUTPUTS*ACC_WIDTH-1:0]       out_value_o
);

    genvar oc_g, k_g, lev_g, node_g;

    generate
        if (PACKED_MODE == 0) begin : GEN_DIRECT
            for (oc_g = 0; oc_g < NUM_OUTPUTS; oc_g = oc_g + 1) begin : GEN_OC
                localparam OC_ROW  = oc_g / NUM_COLS;
                localparam OC_COL  = oc_g % NUM_COLS;
                localparam OC_BASE = OC_ROW * NUM_COLS * K_BITS + OC_COL * K_BITS;

                localparam PIPE_LEVEL   = (LOG2_K_BITS > 1) ? (LOG2_K_BITS / 2) : 0;
                localparam PIPE_NODES   = K_BITS >> PIPE_LEVEL;
                localparam PIPE_OFFSET  = 2*K_BITS - 2*PIPE_NODES;
                localparam UPPER_LEVELS = LOG2_K_BITS - PIPE_LEVEL;

                wire [(2*K_BITS-1)*ACC_WIDTH-1:0] tree_flat;
                reg  [PIPE_NODES*ACC_WIDTH-1:0]   pipe_flat;
                reg                                pipe_valid;
                wire [(2*PIPE_NODES-1)*ACC_WIDTH-1:0] upper_flat;

                for (k_g = 0; k_g < K_BITS; k_g = k_g + 1) begin : GEN_LEAF
                    wire leaf_sel = out_enable_i[oc_g] && lane_valid_i[OC_BASE + k_g];
                    wire [PRODUCT_WIDTH-1:0] product =
                        lane_product_i[(OC_BASE+k_g)*PRODUCT_WIDTH +: PRODUCT_WIDTH];
                    wire [ACC_WIDTH-1:0] product_ext = SIGNED_DATA ?
                        {{(ACC_WIDTH-PRODUCT_WIDTH){product[PRODUCT_WIDTH-1]}}, product} :
                        {{(ACC_WIDTH-PRODUCT_WIDTH){1'b0}}, product};

                    assign tree_flat[k_g*ACC_WIDTH +: ACC_WIDTH] =
                        leaf_sel ? product_ext : {ACC_WIDTH{1'b0}};
                end

                for (lev_g = 1; lev_g <= PIPE_LEVEL; lev_g = lev_g + 1) begin : GEN_LEVEL
                    localparam LW = K_BITS >> lev_g;
                    localparam LO = 2*K_BITS - 2*LW;
                    localparam PO = 2*K_BITS - 4*LW;

                    for (node_g = 0; node_g < LW; node_g = node_g + 1) begin : GEN_NODE
                        assign tree_flat[(LO+node_g)*ACC_WIDTH +: ACC_WIDTH] =
                            tree_flat[(PO+2*node_g  )*ACC_WIDTH +: ACC_WIDTH] +
                            tree_flat[(PO+2*node_g+1)*ACC_WIDTH +: ACC_WIDTH];
                    end
                end

                for (lev_g = PIPE_LEVEL + 1; lev_g <= LOG2_K_BITS; lev_g = lev_g + 1) begin : GEN_UNUSED_LEVEL
                    localparam ULW = K_BITS >> lev_g;
                    localparam ULO = 2*K_BITS - 2*ULW;

                    for (node_g = 0; node_g < ULW; node_g = node_g + 1) begin : GEN_UNUSED_NODE
                        assign tree_flat[(ULO+node_g)*ACC_WIDTH +: ACC_WIDTH] = {ACC_WIDTH{1'b0}};
                    end
                end

                integer p_i;
                always @(posedge clk or posedge reset) begin
                    if (reset) begin
                        pipe_flat  <= {(PIPE_NODES*ACC_WIDTH){1'b0}};
                        pipe_valid <= 1'b0;
                    end else begin
                        pipe_valid <= out_enable_i[oc_g];
                        for (p_i = 0; p_i < PIPE_NODES; p_i = p_i + 1)
                            pipe_flat[p_i*ACC_WIDTH +: ACC_WIDTH] <=
                                tree_flat[(PIPE_OFFSET+p_i)*ACC_WIDTH +: ACC_WIDTH];
                    end
                end

                for (k_g = 0; k_g < PIPE_NODES; k_g = k_g + 1) begin : GEN_UPPER_LEAF
                    assign upper_flat[k_g*ACC_WIDTH +: ACC_WIDTH] =
                        pipe_flat[k_g*ACC_WIDTH +: ACC_WIDTH];
                end

                for (lev_g = 1; lev_g <= UPPER_LEVELS; lev_g = lev_g + 1) begin : GEN_UPPER_LEVEL
                    localparam UW = PIPE_NODES >> lev_g;
                    localparam UO = 2*PIPE_NODES - 2*UW;
                    localparam UP = 2*PIPE_NODES - 4*UW;

                    for (node_g = 0; node_g < UW; node_g = node_g + 1) begin : GEN_UPPER_NODE
                        assign upper_flat[(UO+node_g)*ACC_WIDTH +: ACC_WIDTH] =
                            upper_flat[(UP+2*node_g  )*ACC_WIDTH +: ACC_WIDTH] +
                            upper_flat[(UP+2*node_g+1)*ACC_WIDTH +: ACC_WIDTH];
                    end
                end

                assign out_value_o[oc_g*ACC_WIDTH +: ACC_WIDTH] =
                    upper_flat[(2*PIPE_NODES-2)*ACC_WIDTH +: ACC_WIDTH];
                assign out_valid_o[oc_g] = pipe_valid;
            end

            wire unused_selectors = &{1'b0, a_row_sel_i, b_col_sel_i};
        end else begin : GEN_PACKED
            for (oc_g = 0; oc_g < NUM_OUTPUTS; oc_g = oc_g + 1) begin : GEN_OC
                localparam OC_ROW  = oc_g / NUM_COLS;
                localparam OC_COL  = oc_g % NUM_COLS;

                reg [ACC_WIDTH-1:0] sum_comb;
                reg                 valid_comb;
                reg [ACC_WIDTH-1:0] sum_r;
                reg                 valid_r;
                integer lane_i;

                always @(*) begin
                    sum_comb = {ACC_WIDTH{1'b0}};
                    valid_comb = 1'b0;
                    for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1) begin
                        if (lane_valid_i[lane_i] &&
                            (a_row_sel_i[lane_i*ROW_IDX_W +: ROW_IDX_W] == OC_ROW[ROW_IDX_W-1:0]) &&
                            (b_col_sel_i[lane_i*COL_IDX_W +: COL_IDX_W] == OC_COL[COL_IDX_W-1:0])) begin
                            valid_comb = 1'b1;
                            if (SIGNED_DATA) begin
                                sum_comb = sum_comb +
                                    {{(ACC_WIDTH-PRODUCT_WIDTH){lane_product_i[(lane_i+1)*PRODUCT_WIDTH-1]}},
                                      lane_product_i[lane_i*PRODUCT_WIDTH +: PRODUCT_WIDTH]};
                            end else begin
                                sum_comb = sum_comb +
                                    {{(ACC_WIDTH-PRODUCT_WIDTH){1'b0}},
                                      lane_product_i[lane_i*PRODUCT_WIDTH +: PRODUCT_WIDTH]};
                            end
                        end
                    end
                end

                always @(posedge clk or posedge reset) begin
                    if (reset) begin
                        sum_r <= {ACC_WIDTH{1'b0}};
                        valid_r <= 1'b0;
                    end else begin
                        sum_r <= sum_comb;
                        valid_r <= out_enable_i[oc_g] && valid_comb;
                    end
                end

                assign out_value_o[oc_g*ACC_WIDTH +: ACC_WIDTH] = sum_r;
                assign out_valid_o[oc_g] = valid_r;
            end
        end
    endgenerate

endmodule
