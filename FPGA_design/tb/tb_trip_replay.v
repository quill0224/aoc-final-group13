`timescale 1ns/1ps

// Replay regression for packed MFIU overflow.
//
// Dense 2x2/K=4 produces 16 effectual MACs.  With LANES=6, the tile engine
// must run the same K chunk three times:
//   pass 0 emits events 0..5
//   pass 1 emits events 6..11
//   pass 2 emits events 12..15
//
// All values are 1, so every C element accumulates four products.

module tb_trip_replay;
    localparam NUM_ROWS       = 2;
    localparam NUM_COLS       = 2;
    localparam K_BITS         = 4;
    localparam LANES          = 6;
    localparam DATA_WIDTH     = 16;
    localparam ID_WIDTH       = 4;
    localparam PRODUCT_WIDTH  = DATA_WIDTH * 2;
    localparam ACC_WIDTH      = PRODUCT_WIDTH + $clog2(LANES + 1);
    localparam TILE_ACC_WIDTH = ACC_WIDTH + 8;
    localparam NUM_OUTPUTS    = NUM_ROWS * NUM_COLS;
    localparam VAL_W          = K_BITS * DATA_WIDTH;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset;
    reg start_i;
    reg clear_accum_i;
    reg a_wr_en_i, b_wr_en_i;
    reg [0:0] a_wr_addr_i, b_wr_addr_i;
    reg [ID_WIDTH-1:0] a_wr_id_i, b_wr_id_i;
    reg [K_BITS-1:0] a_wr_mask_i, b_wr_mask_i;
    reg [VAL_W-1:0] a_wr_values_i, b_wr_values_i;

    wire busy_o, done_o, overflow_o, overflow_seen_o;
    wire [NUM_OUTPUTS-1:0] partial_valid_o;
    wire [NUM_OUTPUTS*ACC_WIDTH-1:0] partial_result_o;
    wire [$clog2(LANES+1)-1:0] match_count_o;
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
        .PACKED_MFIU    (1)
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
        .chunk_count_o    (chunk_count_o),
        .test_mode_i      (1'b0),
        .scan_en_i        (1'b0),
        .fsm_state_obs_o  ()
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    reg saw_done;

    function [TILE_ACC_WIDTH-1:0] tile_at;
        input integer idx;
        tile_at = tile_result_o[idx*TILE_ACC_WIDTH +: TILE_ACC_WIDTH];
    endfunction

    task check_int;
        input [255:0] label;
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

    task check_bit;
        input [255:0] label;
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

    task write_a;
        input [0:0] addr;
        begin
            @(negedge clk);
            a_wr_en_i = 1'b1;
            a_wr_addr_i = addr;
            a_wr_id_i = {ID_WIDTH{1'b0}};
            a_wr_mask_i = {K_BITS{1'b1}};
            a_wr_values_i = {16'd1, 16'd1, 16'd1, 16'd1};
            @(negedge clk);
            a_wr_en_i = 1'b0;
        end
    endtask

    task write_b;
        input [0:0] addr;
        begin
            @(negedge clk);
            b_wr_en_i = 1'b1;
            b_wr_addr_i = addr;
            b_wr_id_i = {ID_WIDTH{1'b0}};
            b_wr_mask_i = {K_BITS{1'b1}};
            b_wr_values_i = {16'd1, 16'd1, 16'd1, 16'd1};
            @(negedge clk);
            b_wr_en_i = 1'b0;
        end
    endtask

    task run_tile;
        integer cyc;
        begin
            saw_done = 1'b0;
            @(negedge clk);
            clear_accum_i = 1'b1;
            start_i = 1'b1;
            @(negedge clk);
            start_i = 1'b0;
            clear_accum_i = 1'b0;

            for (cyc = 0; cyc < 300; cyc = cyc + 1) begin
                @(posedge clk);
                if (done_o) begin
                    saw_done = 1'b1;
                    cyc = 300;
                end
            end
            @(negedge clk);
        end
    endtask

    integer i;
    initial begin
        reset = 1'b1;
        start_i = 1'b0;
        clear_accum_i = 1'b0;
        a_wr_en_i = 1'b0;
        b_wr_en_i = 1'b0;
        a_wr_addr_i = 1'b0;
        b_wr_addr_i = 1'b0;
        a_wr_id_i = {ID_WIDTH{1'b0}};
        b_wr_id_i = {ID_WIDTH{1'b0}};
        a_wr_mask_i = {K_BITS{1'b0}};
        b_wr_mask_i = {K_BITS{1'b0}};
        a_wr_values_i = {VAL_W{1'b0}};
        b_wr_values_i = {VAL_W{1'b0}};

        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        write_a(1'b0);
        write_a(1'b1);
        write_b(1'b0);
        write_b(1'b1);

        run_tile;

        check_bit("saw done_o", saw_done, 1'b1);
        check_bit("overflow_seen_o asserted", overflow_seen_o, 1'b1);
        check_bit("overflow_o deasserted on final pass", overflow_o, 1'b0);
        check_int("chunk_count_o", chunk_count_o, 1);
        check_int("final pass match_count_o", match_count_o, 4);
        check_int("tile_valid_o", tile_valid_o, 4'b1111);

        for (i = 0; i < NUM_OUTPUTS; i = i + 1)
            check_int("C element", tile_at(i), 4);

        $display("------------------------------------------");
        $display("tb_trip_replay: %0d passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL PASS");
        else              $display("FAIL");
        $display("------------------------------------------");
        $finish;
    end

endmodule
