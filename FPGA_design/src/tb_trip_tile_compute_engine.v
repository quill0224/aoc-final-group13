`timescale 1ns/1ps

module tb_trip_tile_compute_engine;

    localparam NUM_ROWS       = 2;
    localparam NUM_COLS       = 2;
    localparam K_BITS         = 4;
    localparam LANES          = 4;
    localparam DATA_WIDTH     = 16;
    localparam ID_WIDTH       = 4;
    localparam ADDR_W_A       = 1;
    localparam ADDR_W_B       = 1;
    localparam CNT_W          = 3;
    localparam PRODUCT_WIDTH  = DATA_WIDTH * 2;
    localparam ACC_WIDTH      = PRODUCT_WIDTH + CNT_W;
    localparam TILE_ACC_WIDTH = ACC_WIDTH + 8;
    localparam NUM_OUTPUTS    = NUM_ROWS * NUM_COLS;
    localparam VAL_W          = K_BITS * DATA_WIDTH;

    reg clk, reset, start_i, clear_accum_i;
    reg a_wr_en_i, b_wr_en_i;
    reg [ADDR_W_A-1:0] a_wr_addr_i;
    reg [ADDR_W_B-1:0] b_wr_addr_i;
    reg [ID_WIDTH-1:0] a_wr_id_i, b_wr_id_i;
    reg [K_BITS-1:0] a_wr_mask_i, b_wr_mask_i;
    reg [VAL_W-1:0] a_wr_values_i, b_wr_values_i;

    wire busy_o, done_o;
    wire [NUM_OUTPUTS-1:0] partial_valid_o;
    wire [NUM_OUTPUTS*ACC_WIDTH-1:0] partial_result_o;
    wire [CNT_W-1:0] match_count_o;
    wire overflow_o;
    wire overflow_seen_o;
    wire [NUM_OUTPUTS-1:0] tile_valid_o;
    wire [NUM_OUTPUTS*TILE_ACC_WIDTH-1:0] tile_result_o;
    wire [7:0] chunk_count_o;

    trip_tile_compute_engine #(
        .NUM_ROWS       (NUM_ROWS),
        .NUM_COLS       (NUM_COLS),
        .K_BITS         (K_BITS),
        .LANES          (LANES),
        .DATA_WIDTH     (DATA_WIDTH),
        .ID_WIDTH       (ID_WIDTH),
        .TILE_ACC_WIDTH (TILE_ACC_WIDTH)
    ) dut (
        .clk              (clk),
        .reset            (reset),
        .a_wr_en_i        (a_wr_en_i),
        .a_wr_addr_i      (a_wr_addr_i),
        .a_wr_id_i        (a_wr_id_i),
        .a_wr_mask_i      (a_wr_mask_i),
        .a_wr_values_i    (a_wr_values_i),
        .b_wr_en_i        (b_wr_en_i),
        .b_wr_addr_i      (b_wr_addr_i),
        .b_wr_id_i        (b_wr_id_i),
        .b_wr_mask_i      (b_wr_mask_i),
        .b_wr_values_i    (b_wr_values_i),
        .start_i          (start_i),
        .clear_accum_i    (clear_accum_i),
        .busy_o           (busy_o),
        .done_o           (done_o),
        .partial_valid_o  (partial_valid_o),
        .partial_result_o (partial_result_o),
        .match_count_o    (match_count_o),
        .overflow_o       (overflow_o),
        .overflow_seen_o  (overflow_seen_o),
        .tile_valid_o     (tile_valid_o),
        .tile_result_o    (tile_result_o),
        .chunk_count_o    (chunk_count_o)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    function [TILE_ACC_WIDTH-1:0] get_tile_result;
        input integer idx;
        begin
            get_tile_result = tile_result_o[idx*TILE_ACC_WIDTH +: TILE_ACC_WIDTH];
        end
    endfunction

    function [ACC_WIDTH-1:0] get_partial_result;
        input integer idx;
        begin
            get_partial_result = partial_result_o[idx*ACC_WIDTH +: ACC_WIDTH];
        end
    endfunction

    task check;
        input [199:0] label;
        input got;
        input exp;
        begin
            if (got === exp) begin
                $display("PASS  %s", label);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL  %s got=%0b exp=%0b", label, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task check_int;
        input [199:0] label;
        input integer got;
        input integer exp;
        begin
            if (got === exp) begin
                $display("PASS  %s (%0d)", label, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL  %s got=%0d exp=%0d", label, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task check_vec4;
        input [199:0] label;
        input [3:0] got;
        input [3:0] exp;
        begin
            if (got === exp) begin
                $display("PASS  %s", label);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL  %s got=%0b exp=%0b", label, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task write_a_fiber;
        input [ADDR_W_A-1:0] addr;
        input [ID_WIDTH-1:0] id;
        input [K_BITS-1:0] mask;
        input [VAL_W-1:0] values;
        begin
            @(negedge clk);
            a_wr_en_i     = 1'b1;
            a_wr_addr_i   = addr;
            a_wr_id_i     = id;
            a_wr_mask_i   = mask;
            a_wr_values_i = values;
            @(posedge clk); #1;
            a_wr_en_i = 1'b0;
        end
    endtask

    task write_b_fiber;
        input [ADDR_W_B-1:0] addr;
        input [ID_WIDTH-1:0] id;
        input [K_BITS-1:0] mask;
        input [VAL_W-1:0] values;
        begin
            @(negedge clk);
            b_wr_en_i     = 1'b1;
            b_wr_addr_i   = addr;
            b_wr_id_i     = id;
            b_wr_mask_i   = mask;
            b_wr_values_i = values;
            @(posedge clk); #1;
            b_wr_en_i = 1'b0;
        end
    endtask

    task run_chunk;
        input clear_accum;
        begin
            @(negedge clk);
            start_i       = 1'b1;
            clear_accum_i = clear_accum;
            @(posedge clk); #1;
            start_i       = 1'b0;
            clear_accum_i = 1'b0;
            wait (done_o === 1'b1);
            #1;
        end
    endtask

    initial begin
        reset = 1'b1;
        start_i = 1'b0;
        clear_accum_i = 1'b0;
        a_wr_en_i = 1'b0;
        b_wr_en_i = 1'b0;
        a_wr_addr_i = '0;
        b_wr_addr_i = '0;
        a_wr_id_i = '0;
        b_wr_id_i = '0;
        a_wr_mask_i = '0;
        b_wr_mask_i = '0;
        a_wr_values_i = '0;
        b_wr_values_i = '0;

        repeat (3) @(posedge clk);
        @(negedge clk); reset = 1'b0;

        // Original full matrices for this test:
        //
        // A is 2x8, split into two 2x4 K chunks:
        //   A0 = [0, 2, 0, 3, 1, 0, 4, 0]
        //   A1 = [0,17,19, 0, 0, 5, 0, 6]
        //
        // B is 8x2, split into two 4x2 K chunks:
        //   B0 = [7,0,0,5, 2,0,3,0]^T
        //   B1 = [0,11,0,13, 0,7,0,8]^T
        //
        // Chunk 0 partial C = [[15, 61], [0, 187]]
        // Chunk 1 partial C = [[14,  0], [0,  83]]
        // Final accumulated C = [[29, 61], [0, 270]]

        $display("\n--- TC1: K chunk 0, clear accumulator ---");
        write_a_fiber(0, 0, 4'b1010, {16'd3, 16'd0, 16'd2, 16'd0});
        write_a_fiber(1, 1, 4'b0110, {16'd0, 16'd19, 16'd17, 16'd0});
        write_b_fiber(0, 0, 4'b1001, {16'd5, 16'd0, 16'd0, 16'd7});
        write_b_fiber(1, 1, 4'b1010, {16'd13, 16'd0, 16'd11, 16'd0});
        run_chunk(1'b1);

        check_int("TC1 chunk_count=1    ", chunk_count_o, 1);
        check    ("TC1 overflow_seen=0  ", overflow_seen_o, 1'b0);
        check    ("TC1 valid C00        ", tile_valid_o[0], 1'b1);
        check    ("TC1 valid C01        ", tile_valid_o[1], 1'b1);
        check    ("TC1 invalid C10      ", tile_valid_o[2], 1'b0);
        check    ("TC1 valid C11        ", tile_valid_o[3], 1'b1);
        check_int("TC1 C00=15          ", get_tile_result(0), 15);
        check_int("TC1 C01=61          ", get_tile_result(1), 61);
        check_int("TC1 C10=0           ", get_tile_result(2), 0);
        check_int("TC1 C11=187         ", get_tile_result(3), 187);

        $display("\n--- TC2: K chunk 1, accumulate into same C tile ---");
        write_a_fiber(0, 0, 4'b0101, {16'd0, 16'd4, 16'd0, 16'd1});
        write_a_fiber(1, 1, 4'b1010, {16'd6, 16'd0, 16'd5, 16'd0});
        write_b_fiber(0, 0, 4'b0101, {16'd0, 16'd3, 16'd0, 16'd2});
        write_b_fiber(1, 1, 4'b1010, {16'd8, 16'd0, 16'd7, 16'd0});
        run_chunk(1'b0);

        check_int("TC2 chunk_count=2    ", chunk_count_o, 2);
        check    ("TC2 valid C00        ", tile_valid_o[0], 1'b1);
        check    ("TC2 valid C01        ", tile_valid_o[1], 1'b1);
        check    ("TC2 invalid C10      ", tile_valid_o[2], 1'b0);
        check    ("TC2 valid C11        ", tile_valid_o[3], 1'b1);
        check_int("TC2 partial C00=14  ", get_partial_result(0), 14);
        check_int("TC2 partial C11=83  ", get_partial_result(3), 83);
        check_int("TC2 final C00=29    ", get_tile_result(0), 29);
        check_int("TC2 final C01=61    ", get_tile_result(1), 61);
        check_int("TC2 final C10=0     ", get_tile_result(2), 0);
        check_int("TC2 final C11=270   ", get_tile_result(3), 270);

        $display("\n--- TC3: clear accumulator and run no-intersection tile ---");
        write_a_fiber(0, 0, 4'b1010, {16'd3, 16'd0, 16'd2, 16'd0});
        write_a_fiber(1, 1, 4'b1010, {16'd3, 16'd0, 16'd2, 16'd0});
        write_b_fiber(0, 0, 4'b0101, {16'd0, 16'd5, 16'd0, 16'd7});
        write_b_fiber(1, 1, 4'b0101, {16'd0, 16'd5, 16'd0, 16'd7});
        run_chunk(1'b1);

        check_int("TC3 chunk_count=1    ", chunk_count_o, 1);
        check_vec4("TC3 no valid outputs ", tile_valid_o, 4'b0000);
        check_int("TC3 C00=0           ", get_tile_result(0), 0);
        check_int("TC3 C11=0           ", get_tile_result(3), 0);

        $display("\n------------------------------------------");
        $display("Result: %0d passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("ALL PASS");
        else
            $display("SOME FAILURES");
        $display("------------------------------------------");
        $finish;
    end

endmodule
