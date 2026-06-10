// Minimal multiplier lane for TrIP MVP.

module pe_lane #(
    parameter DATA_WIDTH    = 16,
    parameter PRODUCT_WIDTH = DATA_WIDTH * 2
) (
    input  wire                    valid_i,
    input  wire [DATA_WIDTH-1:0]   a_i,
    input  wire [DATA_WIDTH-1:0]   b_i,
    output wire                    valid_o,
    output wire [PRODUCT_WIDTH-1:0] product_o
);

    assign valid_o   = valid_i;
    assign product_o = valid_i ? (a_i * b_i) : {PRODUCT_WIDTH{1'b0}};

endmodule
