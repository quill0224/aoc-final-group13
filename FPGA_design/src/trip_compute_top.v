// End-to-end TrIP MVP compute path.
//
// bitmask buffers -> MFIU -> small A/B distribution -> multiplier lanes ->
// reduction-by-output-coordinate -> row-local buffer.
//
// LANES is the packed effectual-MAC capacity.  If a chunk produces more
// effectual MACs than LANES, MFIU asserts overflow_o.

module trip_compute_top #(
    parameter NUM_ROWS      = 4,
    parameter NUM_COLS      = 4,
    parameter K_BITS        = 4,
    parameter LANES         = 64,
    parameter DATA_WIDTH    = 16,
    parameter ID_WIDTH      = 4,
    parameter PRODUCT_WIDTH = DATA_WIDTH * 2,
    parameter ACC_WIDTH     = PRODUCT_WIDTH + $clog2(LANES + 1),
    parameter SIGNED_DATA   = 0,
    parameter PACKED_MFIU   = 0,
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
    reg  [NUM_OUTPUTS-1:0] per_output_valid_d1;
    reg  [NUM_OUTPUTS-1:0] per_output_valid_d2;
    reg  [NUM_OUTPUTS-1:0] per_output_valid_d3;
    reg  reduce_write_en_d1;
    reg  reduce_write_en_d2;
    reg  reduce_write_en_d3;
    reg  reduce_write_en_d4;
    reg  reduce_write_en_d5;
    wire [NUM_OUTPUTS-1:0] reduce_valid;
    wire [NUM_OUTPUTS*ACC_WIDTH-1:0] reduce_value;
    reg  [NUM_OUTPUTS-1:0] reduce_valid_r;
    reg  [NUM_OUTPUTS*ACC_WIDTH-1:0] reduce_value_r;

    // per-output enable: high when >= 1 lane targets this (row, col) slot.
    // With direct MFIU mapping, lanes for output oc are contiguous:
    //   LANE_BASE = (oc/NUM_COLS)*NUM_COLS*K_BITS + (oc%NUM_COLS)*K_BITS
    reg [NUM_OUTPUTS-1:0] per_output_valid;
    integer pov_i, pov_lane_i;
    integer pov_base;
    always @(*) begin
        per_output_valid = {NUM_OUTPUTS{1'b0}};
        pov_base = 0;
        if (PACKED_MFIU) begin
            for (pov_lane_i = 0; pov_lane_i < LANES; pov_lane_i = pov_lane_i + 1) begin
                if (lane_valid[pov_lane_i]) begin
                    for (pov_i = 0; pov_i < NUM_OUTPUTS; pov_i = pov_i + 1) begin
                        if ((a_row_sel[pov_lane_i*ROW_IDX_W +: ROW_IDX_W] == (pov_i / NUM_COLS)) &&
                            (b_col_sel[pov_lane_i*COL_IDX_W +: COL_IDX_W] == (pov_i % NUM_COLS))) begin
                            per_output_valid[pov_i] = 1'b1;
                        end
                    end
                end
            end
        end else begin
            for (pov_i = 0; pov_i < NUM_OUTPUTS; pov_i = pov_i + 1) begin
                pov_base = (pov_i / NUM_COLS) * NUM_COLS * K_BITS + (pov_i % NUM_COLS) * K_BITS;
                per_output_valid[pov_i] = |lane_valid[pov_base +: K_BITS];
            end
        end
    end

    trip_intersection_top #(
        .NUM_ROWS   (NUM_ROWS),
        .NUM_COLS   (NUM_COLS),
        .K_BITS     (K_BITS),
        .LANES      (LANES),
        .DATA_WIDTH (DATA_WIDTH),
        .ID_WIDTH   (ID_WIDTH),
        .PACKED_MFIU(PACKED_MFIU)
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
        .active_b_cols_o(),
        .overflow_o    (overflow_o),
        .a_values_o    (captured_a_values),
        .b_values_o    (captured_b_values)
    );

    trip_distribution_network #(
        .NUM_ROWS   (NUM_ROWS),
        .NUM_COLS   (NUM_COLS),
        .K_BITS     (K_BITS),
        .LANES      (LANES),
        .DATA_WIDTH (DATA_WIDTH),
        .PACKED_MODE(PACKED_MFIU)
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
                .clk       (clk),
                .reset     (reset),
                .valid_i   (dist_valid[gl]),
                .a_i       (dist_a[gl*DATA_WIDTH +: DATA_WIDTH]),
                .b_i       (dist_b[gl*DATA_WIDTH +: DATA_WIDTH]),
                .valid_o   (product_valid[gl]),
                .product_o (products[gl*PRODUCT_WIDTH +: PRODUCT_WIDTH])
            );
        end
    endgenerate

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            per_output_valid_d1 <= {NUM_OUTPUTS{1'b0}};
            per_output_valid_d2 <= {NUM_OUTPUTS{1'b0}};
            per_output_valid_d3 <= {NUM_OUTPUTS{1'b0}};
            reduce_write_en_d1  <= 1'b0;
            reduce_write_en_d2  <= 1'b0;
            reduce_write_en_d3  <= 1'b0;
            reduce_write_en_d4  <= 1'b0;
            reduce_write_en_d5  <= 1'b0;
            reduce_valid_r      <= {NUM_OUTPUTS{1'b0}};
            reduce_value_r      <= {(NUM_OUTPUTS*ACC_WIDTH){1'b0}};
        end else begin
            per_output_valid_d1 <= per_output_valid;
            per_output_valid_d2 <= per_output_valid_d1;
            per_output_valid_d3 <= per_output_valid_d2;
            reduce_write_en_d1  <= intersection_done;
            reduce_write_en_d2  <= reduce_write_en_d1;
            reduce_write_en_d3  <= reduce_write_en_d2;
            reduce_write_en_d4  <= reduce_write_en_d3;
            reduce_write_en_d5  <= reduce_write_en_d4;
            reduce_valid_r      <= reduce_valid;
            reduce_value_r      <= reduce_value;
        end
    end

    trip_reduction_tree #(
        .NUM_ROWS      (NUM_ROWS),
        .NUM_COLS      (NUM_COLS),
        .K_BITS        (K_BITS),
        .LANES         (LANES),
        .DATA_WIDTH    (DATA_WIDTH),
        .PRODUCT_WIDTH (PRODUCT_WIDTH),
        .ACC_WIDTH     (ACC_WIDTH),
        .SIGNED_DATA   (SIGNED_DATA),
        .PACKED_MODE   (PACKED_MFIU)
    ) u_reduce (
        .clk            (clk),
        .reset          (reset),
        .lane_valid_i   (product_valid),
        .a_row_sel_i    (a_row_sel),
        .b_col_sel_i    (b_col_sel),
        .lane_product_i (products),
        .out_enable_i   (per_output_valid_d3),
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
        .wr_en_i    (reduce_write_en_d5),
        .wr_valid_i (reduce_valid_r),
        .wr_data_i  (reduce_value_r),
        .rd_valid_o (result_valid_o),
        .rd_data_o  (result_o)
    );

    always @(posedge clk or posedge reset) begin
        if (reset)
            done_o <= 1'b0;
        else
            done_o <= reduce_write_en_d5;
    end

endmodule
