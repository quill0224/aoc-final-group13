// Minimal multiplier lane for TrIP MVP.

module pe_lane #(
    parameter DATA_WIDTH    = 16,
    parameter PRODUCT_WIDTH = DATA_WIDTH * 2,
    parameter SIGNED_DATA   = 0
) (
    input  wire                    valid_i,
    input  wire [DATA_WIDTH-1:0]   a_i,
    input  wire [DATA_WIDTH-1:0]   b_i,
    output wire                    valid_o,
    output wire [PRODUCT_WIDTH-1:0] product_o
);

    assign valid_o   = valid_i;

    generate
        if (SIGNED_DATA) begin : gen_signed_mul
            wire signed [DATA_WIDTH-1:0] signed_a;
            wire signed [DATA_WIDTH-1:0] signed_b;
            wire signed [PRODUCT_WIDTH-1:0] signed_product;

            assign signed_a = a_i;
            assign signed_b = b_i;
            assign signed_product = signed_a * signed_b;
            assign product_o = valid_i ? signed_product : {PRODUCT_WIDTH{1'b0}};
        end else begin : gen_unsigned_mul
            assign product_o = valid_i ? (a_i * b_i) : {PRODUCT_WIDTH{1'b0}};
        end
    endgenerate

endmodule
