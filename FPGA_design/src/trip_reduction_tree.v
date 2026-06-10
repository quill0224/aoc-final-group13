// Reduction-only merge/reduction tree for TrIP MVP.
//
// Groups lane products by output tag (A row, B column). This models the
// TrIP reduction mode before a later replacement with a real MRN-style tree.

module trip_reduction_tree #(
    parameter NUM_ROWS      = 2,
    parameter NUM_COLS      = 2,
    parameter LANES         = 4,
    parameter DATA_WIDTH    = 16,
    parameter PRODUCT_WIDTH = DATA_WIDTH * 2,
    parameter ACC_WIDTH     = PRODUCT_WIDTH + $clog2(LANES + 1),
    // derived
    parameter ROW_IDX_W     = (NUM_ROWS > 1) ? $clog2(NUM_ROWS) : 1,
    parameter COL_IDX_W     = (NUM_COLS > 1) ? $clog2(NUM_COLS) : 1
) (
    input  wire [LANES-1:0]                    lane_valid_i,
    input  wire [LANES*ROW_IDX_W-1:0]          a_row_sel_i,
    input  wire [LANES*COL_IDX_W-1:0]          b_col_sel_i,
    input  wire [LANES*PRODUCT_WIDTH-1:0]      lane_product_i,

    output reg  [NUM_ROWS*NUM_COLS-1:0]        out_valid_o,
    output reg  [NUM_ROWS*NUM_COLS*ACC_WIDTH-1:0] out_value_o
);

    integer r, c, l;
    reg [ROW_IDX_W-1:0] lane_row;
    reg [COL_IDX_W-1:0] lane_col;
    reg [PRODUCT_WIDTH-1:0] lane_product;
    reg [ACC_WIDTH-1:0] sum;
    integer out_idx;

    always @(*) begin
        out_valid_o = {(NUM_ROWS*NUM_COLS){1'b0}};
        out_value_o = {(NUM_ROWS*NUM_COLS*ACC_WIDTH){1'b0}};

        for (r = 0; r < NUM_ROWS; r = r + 1) begin
            for (c = 0; c < NUM_COLS; c = c + 1) begin
                sum = {ACC_WIDTH{1'b0}};
                for (l = 0; l < LANES; l = l + 1) begin
                    lane_row     = a_row_sel_i[l*ROW_IDX_W +: ROW_IDX_W];
                    lane_col     = b_col_sel_i[l*COL_IDX_W +: COL_IDX_W];
                    lane_product = lane_product_i[l*PRODUCT_WIDTH +: PRODUCT_WIDTH];

                    if (lane_valid_i[l] && (lane_row == r[ROW_IDX_W-1:0]) &&
                        (lane_col == c[COL_IDX_W-1:0])) begin
                        sum = sum + {{(ACC_WIDTH-PRODUCT_WIDTH){1'b0}}, lane_product};
                    end
                end

                out_idx = r * NUM_COLS + c;
                if (sum != {ACC_WIDTH{1'b0}}) begin
                    out_valid_o[out_idx] = 1'b1;
                    out_value_o[out_idx*ACC_WIDTH +: ACC_WIDTH] = sum;
                end
            end
        end
    end

endmodule
