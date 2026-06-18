`timescale 1ns/1ps

module tb_trip_compute_top;

    localparam NUM_ROWS      = 2;
    localparam NUM_COLS      = 2;
    localparam K_BITS        = 4;
    localparam LANES         = 16;
    localparam DATA_WIDTH    = 16;
    localparam ID_WIDTH      = 4;
    localparam ADDR_W_A      = 1;
    localparam ADDR_W_B      = 1;
    localparam CNT_W         = 5;
    localparam PRODUCT_WIDTH = DATA_WIDTH * 2;
    localparam ACC_WIDTH     = PRODUCT_WIDTH + CNT_W;
    localparam NUM_OUTPUTS   = NUM_ROWS * NUM_COLS;
    localparam VAL_W         = K_BITS * DATA_WIDTH;

    reg clk, reset, start_i;
    reg a_wr_en_i, b_wr_en_i;
    reg [ADDR_W_A-1:0] a_wr_addr_i;
    reg [ADDR_W_B-1:0] b_wr_addr_i;
    reg [ID_WIDTH-1:0] a_wr_id_i, b_wr_id_i;
    reg [K_BITS-1:0] a_wr_mask_i, b_wr_mask_i;
    reg [VAL_W-1:0] a_wr_values_i, b_wr_values_i;

    wire done_o;
    wire [NUM_OUTPUTS-1:0] result_valid_o;
    wire [NUM_OUTPUTS*ACC_WIDTH-1:0] result_o;
    wire [CNT_W-1:0] match_count_o;
    wire overflow_o;

    trip_compute_top #(
        .NUM_ROWS   (NUM_ROWS),
        .NUM_COLS   (NUM_COLS),
        .K_BITS     (K_BITS),
        .LANES      (LANES),
        .DATA_WIDTH (DATA_WIDTH),
        .ID_WIDTH   (ID_WIDTH)
    ) dut (
        .clk            (clk),
        .reset          (reset),
        .a_wr_en_i      (a_wr_en_i),
        .a_wr_addr_i    (a_wr_addr_i),
        .a_wr_id_i      (a_wr_id_i),
        .a_wr_mask_i    (a_wr_mask_i),
        .a_wr_values_i  (a_wr_values_i),
        .b_wr_en_i      (b_wr_en_i),
        .b_wr_addr_i    (b_wr_addr_i),
        .b_wr_id_i      (b_wr_id_i),
        .b_wr_mask_i    (b_wr_mask_i),
        .b_wr_values_i  (b_wr_values_i),
        .start_i        (start_i),
        .replay_skip_i  ('0),
        .done_o         (done_o),
        .result_valid_o (result_valid_o),
        .result_o       (result_o),
        .match_count_o  (match_count_o),
        .overflow_o     (overflow_o)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    function [ACC_WIDTH-1:0] get_result;
        input integer idx;
        begin
            get_result = result_o[idx*ACC_WIDTH +: ACC_WIDTH];
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

    task run_compute;
        begin
            @(negedge clk);
            start_i = 1'b1;
            @(posedge clk); #1;
            start_i = 1'b0;
            wait (done_o === 1'b1);
            #1;
        end
    endtask

    initial begin
        reset = 1'b1;
        start_i = 1'b0;
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

        // A0 valid at k1=2, k3=3.
        // A1 valid at k1=17, k2=19.
        // B0 valid at k0=7, k3=5.
        // B1 valid at k1=11, k3=13.
        //
        // Matches:
        // C00: A0[k3] * B0[k3] = 3 * 5 = 15
        // C01: A0[k1] * B1[k1] + A0[k3] * B1[k3] = 2*11 + 3*13 = 61
        // C10: none
        // C11: A1[k1] * B1[k1] = 17 * 11 = 187
        $display("\n--- TC1: end-to-end TrIP compute ---");
        write_a_fiber(0, 0, 4'b1010, {16'd3, 16'd0, 16'd2, 16'd0});
        write_a_fiber(1, 1, 4'b0110, {16'd0, 16'd19, 16'd17, 16'd0});
        write_b_fiber(0, 0, 4'b1001, {16'd5, 16'd0, 16'd0, 16'd7});
        write_b_fiber(1, 1, 4'b1010, {16'd13, 16'd0, 16'd11, 16'd0});
        run_compute;

        check    ("TC1 done_o=1          ", done_o, 1'b1);
        check_int("TC1 match_count=4    ", match_count_o, 4);
        check    ("TC1 overflow=0        ", overflow_o, 1'b0);
        check    ("TC1 valid C00         ", result_valid_o[0], 1'b1);
        check    ("TC1 valid C01         ", result_valid_o[1], 1'b1);
        check    ("TC1 invalid C10       ", result_valid_o[2], 1'b0);
        check    ("TC1 valid C11         ", result_valid_o[3], 1'b1);
        check_int("TC1 C00=15           ", get_result(0), 15);
        check_int("TC1 C01=61           ", get_result(1), 61);
        check_int("TC1 C10=0            ", get_result(2), 0);
        check_int("TC1 C11=187          ", get_result(3), 187);

        $display("\n--- TC2: no intersections clears row buffer ---");
        write_a_fiber(0, 0, 4'b1010, {16'd3, 16'd0, 16'd2, 16'd0});
        write_a_fiber(1, 1, 4'b1010, {16'd3, 16'd0, 16'd2, 16'd0});
        write_b_fiber(0, 0, 4'b0101, {16'd0, 16'd5, 16'd0, 16'd7});
        write_b_fiber(1, 1, 4'b0101, {16'd0, 16'd5, 16'd0, 16'd7});
        run_compute;

        check    ("TC2 done_o=1          ", done_o, 1'b1);
        check_int("TC2 match_count=0    ", match_count_o, 0);
        check    ("TC2 overflow=0        ", overflow_o, 1'b0);
        check    ("TC2 no valid outputs  ", result_valid_o, 4'b0000);
        check_int("TC2 C00=0            ", get_result(0), 0);
        check_int("TC2 C11=0            ", get_result(3), 0);

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
