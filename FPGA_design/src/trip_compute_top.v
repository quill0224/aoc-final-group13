// End-to-end TrIP MVP compute path.
//
// bitmask buffers -> MFIU -> small A/B distribution -> multiplier lanes ->
// reduction-by-output-coordinate -> row-local buffer.

module trip_compute_top #(
    parameter NUM_ROWS      = 2,
    parameter NUM_COLS      = 2,
    parameter K_BITS        = 4,
    parameter LANES         = 4,
    parameter DATA_WIDTH    = 16,
    parameter ID_WIDTH      = 4,
    parameter PRODUCT_WIDTH = DATA_WIDTH * 2,
    parameter ACC_WIDTH     = PRODUCT_WIDTH + $clog2(LANES + 1),
    parameter SIGNED_DATA   = 0,
    // derived
    parameter ADDR_W_A      = (NUM_ROWS > 1) ? $clog2(NUM_ROWS) : 1,
    parameter ADDR_W_B      = (NUM_COLS > 1) ? $clog2(NUM_COLS) : 1,
    parameter ROW_IDX_W     = (NUM_ROWS > 1) ? $clog2(NUM_ROWS) : 1,
    parameter COL_IDX_W     = (NUM_COLS > 1) ? $clog2(NUM_COLS) : 1,
    parameter K_IDX_W       = (K_BITS   > 1) ? $clog2(K_BITS)   : 1,
    parameter CNT_W         = $clog2(LANES + 1),
    parameter NUM_OUTPUTS   = NUM_ROWS * NUM_COLS
) (
    input  wire clk,
    input  wire reset,

    input  wire                           a_wr_en_i,
    input  wire [ADDR_W_A-1:0]            a_wr_addr_i,
    input  wire [ID_WIDTH-1:0]            a_wr_id_i,
    input  wire [K_BITS-1:0]              a_wr_mask_i,
    input  wire [K_BITS*DATA_WIDTH-1:0]   a_wr_values_i,

    input  wire                           b_wr_en_i,
    input  wire [ADDR_W_B-1:0]            b_wr_addr_i,
    input  wire [ID_WIDTH-1:0]            b_wr_id_i,
    input  wire [K_BITS-1:0]              b_wr_mask_i,
    input  wire [K_BITS*DATA_WIDTH-1:0]   b_wr_values_i,

    input  wire start_i,
    output reg  done_o,

    output wire [NUM_OUTPUTS-1:0]         result_valid_o,
    output wire [NUM_OUTPUTS*ACC_WIDTH-1:0] result_o,
    output wire [CNT_W-1:0]               match_count_o,
    output wire                           overflow_o
);

    wire intersection_done;
    wire [LANES-1:0] lane_valid;
    wire [LANES*ROW_IDX_W-1:0] a_row_sel;
    wire [LANES*COL_IDX_W-1:0] b_col_sel;
    wire [LANES*K_IDX_W-1:0]   k_sel;
    wire [NUM_ROWS*K_BITS*DATA_WIDTH-1:0] captured_a_values;
    wire [NUM_COLS*K_BITS*DATA_WIDTH-1:0] captured_b_values;

    wire [LANES-1:0] dist_valid;
    wire [LANES*DATA_WIDTH-1:0] dist_a;
    wire [LANES*DATA_WIDTH-1:0] dist_b;
    wire [LANES-1:0] product_valid;
    wire [LANES*PRODUCT_WIDTH-1:0] products;
    wire [NUM_OUTPUTS-1:0] reduce_valid;
    wire [NUM_OUTPUTS*ACC_WIDTH-1:0] reduce_value;

    trip_intersection_top #(
        .NUM_ROWS   (NUM_ROWS),
        .NUM_COLS   (NUM_COLS),
        .K_BITS     (K_BITS),
        .LANES      (LANES),
        .DATA_WIDTH (DATA_WIDTH),
        .ID_WIDTH   (ID_WIDTH)
    ) u_intersection (
        .clk           (clk),
        .reset         (reset),
        .a_wr_en_i     (a_wr_en_i),
        .a_wr_addr_i   (a_wr_addr_i),
        .a_wr_id_i     (a_wr_id_i),
        .a_wr_mask_i   (a_wr_mask_i),
        .a_wr_values_i (a_wr_values_i),
        .b_wr_en_i     (b_wr_en_i),
        .b_wr_addr_i   (b_wr_addr_i),
        .b_wr_id_i     (b_wr_id_i),
        .b_wr_mask_i   (b_wr_mask_i),
        .b_wr_values_i (b_wr_values_i),
        .start_i       (start_i),
        .done_o        (intersection_done),
        .lane_valid_o  (lane_valid),
        .a_row_sel_o   (a_row_sel),
        .b_col_sel_o   (b_col_sel),
        .k_sel_o       (k_sel),
        .match_count_o (match_count_o),
        .overflow_o    (overflow_o),
        .a_values_o    (captured_a_values),
        .b_values_o    (captured_b_values)
    );

    trip_distribution_network #(
        .NUM_ROWS   (NUM_ROWS),
        .NUM_COLS   (NUM_COLS),
        .K_BITS     (K_BITS),
        .LANES      (LANES),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_dist (
        .a_values_i    (captured_a_values),
        .b_values_i    (captured_b_values),
        .lane_valid_i  (lane_valid),
        .a_row_sel_i   (a_row_sel),
        .b_col_sel_i   (b_col_sel),
        .k_sel_i       (k_sel),
        .lane_valid_o  (dist_valid),
        .lane_a_o      (dist_a),
        .lane_b_o      (dist_b)
    );

    genvar gl;
    generate
        for (gl = 0; gl < LANES; gl = gl + 1) begin : gen_lanes
            pe_lane #(
                .DATA_WIDTH    (DATA_WIDTH),
                .PRODUCT_WIDTH (PRODUCT_WIDTH),
                .SIGNED_DATA   (SIGNED_DATA)
            ) u_lane (
                .valid_i   (dist_valid[gl]),
                .a_i       (dist_a[gl*DATA_WIDTH +: DATA_WIDTH]),
                .b_i       (dist_b[gl*DATA_WIDTH +: DATA_WIDTH]),
                .valid_o   (product_valid[gl]),
                .product_o (products[gl*PRODUCT_WIDTH +: PRODUCT_WIDTH])
            );
        end
    endgenerate

    trip_reduction_tree #(
        .NUM_ROWS      (NUM_ROWS),
        .NUM_COLS      (NUM_COLS),
        .LANES         (LANES),
        .DATA_WIDTH    (DATA_WIDTH),
        .PRODUCT_WIDTH (PRODUCT_WIDTH),
        .ACC_WIDTH     (ACC_WIDTH),
        .SIGNED_DATA   (SIGNED_DATA)
    ) u_reduce (
        .lane_valid_i   (product_valid),
        .a_row_sel_i    (a_row_sel),
        .b_col_sel_i    (b_col_sel),
        .lane_product_i (products),
        .out_valid_o    (reduce_valid),
        .out_value_o    (reduce_value)
    );

    row_local_buffer #(
        .NUM_ROWS   (NUM_ROWS),
        .NUM_COLS   (NUM_COLS),
        .DATA_WIDTH (ACC_WIDTH)
    ) u_row_buf (
        .clk        (clk),
        .reset      (reset),
        .wr_en_i    (intersection_done),
        .wr_valid_i (reduce_valid),
        .wr_data_i  (reduce_value),
        .rd_valid_o (result_valid_o),
        .rd_data_o  (result_o)
    );

    always @(posedge clk or posedge reset) begin
        if (reset)
            done_o <= 1'b0;
        else
            done_o <= intersection_done;
    end

endmodule
