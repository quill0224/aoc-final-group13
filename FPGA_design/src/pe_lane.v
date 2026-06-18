// Minimal multiplier lane for TrIP MVP.

module pe_lane #(
    parameter DATA_WIDTH    = 16,
    parameter PRODUCT_WIDTH = DATA_WIDTH * 2,
    parameter SIGNED_DATA   = 0
) (
    input  wire                    clk,
    input  wire                    reset,
    input  wire                    valid_i,
    input  wire [DATA_WIDTH-1:0]   a_i,
    input  wire [DATA_WIDTH-1:0]   b_i,
    output reg                     valid_o,
    output reg  [PRODUCT_WIDTH-1:0] product_o
);

    generate
        if (SIGNED_DATA) begin : gen_signed_mul
            reg in_valid;
            reg [DATA_WIDTH-1:0] a_r;
            reg [DATA_WIDTH-1:0] b_r;
            wire signed [DATA_WIDTH-1:0] signed_a = a_r;
            wire signed [DATA_WIDTH-1:0] signed_b = b_r;
            wire signed [PRODUCT_WIDTH-1:0] signed_product = signed_a * signed_b;
            reg stage_valid;
            reg signed [PRODUCT_WIDTH-1:0] stage_product;

            always @(posedge clk or posedge reset) begin
                if (reset) begin
                    in_valid     <= 1'b0;
                    a_r          <= {DATA_WIDTH{1'b0}};
                    b_r          <= {DATA_WIDTH{1'b0}};
                    stage_valid  <= 1'b0;
                    stage_product <= {PRODUCT_WIDTH{1'b0}};
                    valid_o       <= 1'b0;
                    product_o     <= {PRODUCT_WIDTH{1'b0}};
                end else begin
                    in_valid     <= valid_i;
                    a_r          <= valid_i ? a_i : {DATA_WIDTH{1'b0}};
                    b_r          <= valid_i ? b_i : {DATA_WIDTH{1'b0}};
                    stage_valid  <= in_valid;
                    stage_product <= in_valid ? signed_product : {PRODUCT_WIDTH{1'b0}};
                    valid_o       <= stage_valid;
                    product_o     <= stage_valid ? stage_product : {PRODUCT_WIDTH{1'b0}};
                end
            end
        end else begin : gen_unsigned_mul
            localparam HALF_WIDTH = DATA_WIDTH / 2;
            localparam HIGH_WIDTH = DATA_WIDTH - HALF_WIDTH;

            reg in_valid;
            reg [DATA_WIDTH-1:0] a_r;
            reg [DATA_WIDTH-1:0] b_r;
            reg stage_valid;
            reg [HALF_WIDTH+DATA_WIDTH-1:0] low_partial;
            reg [HIGH_WIDTH+DATA_WIDTH-1:0] high_partial;

            wire [HALF_WIDTH-1:0] a_low = a_r[HALF_WIDTH-1:0];
            wire [HIGH_WIDTH-1:0] a_high = a_r[DATA_WIDTH-1:HALF_WIDTH];
            wire [PRODUCT_WIDTH-1:0] low_ext =
                {{(PRODUCT_WIDTH-(HALF_WIDTH+DATA_WIDTH)){1'b0}}, low_partial};
            wire [PRODUCT_WIDTH-1:0] high_ext =
                {{(PRODUCT_WIDTH-(HIGH_WIDTH+DATA_WIDTH)){1'b0}}, high_partial};
            wire [PRODUCT_WIDTH-1:0] high_shifted = high_ext << HALF_WIDTH;

            always @(posedge clk or posedge reset) begin
                if (reset) begin
                    in_valid    <= 1'b0;
                    a_r         <= {DATA_WIDTH{1'b0}};
                    b_r         <= {DATA_WIDTH{1'b0}};
                    stage_valid  <= 1'b0;
                    low_partial  <= {(HALF_WIDTH+DATA_WIDTH){1'b0}};
                    high_partial <= {(HIGH_WIDTH+DATA_WIDTH){1'b0}};
                    valid_o      <= 1'b0;
                    product_o    <= {PRODUCT_WIDTH{1'b0}};
                end else begin
                    in_valid    <= valid_i;
                    a_r         <= valid_i ? a_i : {DATA_WIDTH{1'b0}};
                    b_r         <= valid_i ? b_i : {DATA_WIDTH{1'b0}};
                    stage_valid  <= in_valid;
                    low_partial  <= in_valid ? (a_low * b_r) : {(HALF_WIDTH+DATA_WIDTH){1'b0}};
                    high_partial <= in_valid ? (a_high * b_r) : {(HIGH_WIDTH+DATA_WIDTH){1'b0}};
                    valid_o      <= stage_valid;
                    product_o    <= stage_valid ? (low_ext + high_shifted) : {PRODUCT_WIDTH{1'b0}};
                end
            end
        end
    endgenerate

endmodule
