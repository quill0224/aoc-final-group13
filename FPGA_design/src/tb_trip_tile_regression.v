`timescale 1ns/1ps

// Broader regression tests for the TrIP MVP tile engine.
//
// Run one top at a time, for example:
//   iverilog -g2012 -s tb_trip_tile_regression ...
//   iverilog -g2012 -s tb_trip_signed_compute ...
//   iverilog -g2012 -s tb_trip_param_shapes ...

module tb_trip_tile_regression;

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

    wire busy_o, done_o, overflow_o, overflow_seen_o;
    wire [NUM_OUTPUTS-1:0] tile_valid_o;
    wire [NUM_OUTPUTS*TILE_ACC_WIDTH-1:0] tile_result_o;
    wire [NUM_OUTPUTS-1:0] partial_valid_o;
    wire [NUM_OUTPUTS*ACC_WIDTH-1:0] partial_result_o;
    wire [CNT_W-1:0] match_count_o;
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
    integer seed = 32'h1357_2468;
    integer golden [0:NUM_OUTPUTS-1];
    reg [DATA_WIDTH-1:0] a_vals [0:NUM_ROWS-1][0:K_BITS-1];
    reg [DATA_WIDTH-1:0] b_vals [0:NUM_COLS-1][0:K_BITS-1];

    function [TILE_ACC_WIDTH-1:0] tile_result_at;
        input integer idx;
        begin
            tile_result_at = tile_result_o[idx*TILE_ACC_WIDTH +: TILE_ACC_WIDTH];
        end
    endfunction

    function [ACC_WIDTH-1:0] partial_result_at;
        input integer idx;
        begin
            partial_result_at = partial_result_o[idx*ACC_WIDTH +: ACC_WIDTH];
        end
    endfunction

    function [VAL_W-1:0] pack_a_values;
        input integer row;
        begin
            pack_a_values = {a_vals[row][3], a_vals[row][2], a_vals[row][1], a_vals[row][0]};
        end
    endfunction

    function [VAL_W-1:0] pack_b_values;
        input integer col;
        begin
            pack_b_values = {b_vals[col][3], b_vals[col][2], b_vals[col][1], b_vals[col][0]};
        end
    endfunction

    function [K_BITS-1:0] mask_a_values;
        input integer row;
        integer k;
        begin
            mask_a_values = {K_BITS{1'b0}};
            for (k = 0; k < K_BITS; k = k + 1)
                if (a_vals[row][k] != 0)
                    mask_a_values[k] = 1'b1;
        end
    endfunction

    function [K_BITS-1:0] mask_b_values;
        input integer col;
        integer k;
        begin
            mask_b_values = {K_BITS{1'b0}};
            for (k = 0; k < K_BITS; k = k + 1)
                if (b_vals[col][k] != 0)
                    mask_b_values[k] = 1'b1;
        end
    endfunction

    function integer count_matches;
        input integer dummy; // Verilog-2001: functions require ≥1 input
        integer r, c, k;
        begin
            count_matches = 0;
            for (r = 0; r < NUM_ROWS; r = r + 1)
                for (c = 0; c < NUM_COLS; c = c + 1)
                    for (k = 0; k < K_BITS; k = k + 1)
                        if ((a_vals[r][k] != 0) && (b_vals[c][k] != 0))
                            count_matches = count_matches + 1;
        end
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

    task write_current_chunk;
        begin
            write_a_fiber(0, 0, mask_a_values(0), pack_a_values(0));
            write_a_fiber(1, 1, mask_a_values(1), pack_a_values(1));
            write_b_fiber(0, 0, mask_b_values(0), pack_b_values(0));
            write_b_fiber(1, 1, mask_b_values(1), pack_b_values(1));
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

    task run_chunk_hold_start;
        input clear_accum;
        input integer cycles;
        integer i;
        begin
            @(negedge clk);
            start_i       = 1'b1;
            clear_accum_i = clear_accum;
            for (i = 0; i < cycles; i = i + 1)
                @(posedge clk);
            #1;
            start_i       = 1'b0;
            clear_accum_i = 1'b0;
            wait (done_o === 1'b1);
            #1;
        end
    endtask

    task golden_clear;
        integer i;
        begin
            for (i = 0; i < NUM_OUTPUTS; i = i + 1)
                golden[i] = 0;
        end
    endtask

    task golden_add_current_chunk;
        integer r, c, k, idx;
        begin
            for (r = 0; r < NUM_ROWS; r = r + 1) begin
                for (c = 0; c < NUM_COLS; c = c + 1) begin
                    idx = r * NUM_COLS + c;
                    for (k = 0; k < K_BITS; k = k + 1) begin
                        if ((a_vals[r][k] != 0) && (b_vals[c][k] != 0))
                            golden[idx] = golden[idx] + (a_vals[r][k] * b_vals[c][k]);
                    end
                end
            end
        end
    endtask

    task check_against_golden;
        input [255:0] label;
        integer idx;
        begin
            for (idx = 0; idx < NUM_OUTPUTS; idx = idx + 1)
                check_int(label, tile_result_at(idx), golden[idx]);
        end
    endtask

    task clear_current_chunk;
        integer r, c, k;
        begin
            for (r = 0; r < NUM_ROWS; r = r + 1)
                for (k = 0; k < K_BITS; k = k + 1)
                    a_vals[r][k] = 0;
            for (c = 0; c < NUM_COLS; c = c + 1)
                for (k = 0; k < K_BITS; k = k + 1)
                    b_vals[c][k] = 0;
        end
    endtask

    task make_random_chunk_no_overflow;
        integer r, c, k, attempts;
        begin
            attempts = 0;
            while (attempts < 100) begin
                attempts = attempts + 1;
                clear_current_chunk;
                for (r = 0; r < NUM_ROWS; r = r + 1)
                    for (k = 0; k < K_BITS; k = k + 1)
                        if (($random(seed) & 7) == 0)
                            a_vals[r][k] = (($random(seed) & 7) + 1);
                for (c = 0; c < NUM_COLS; c = c + 1)
                    for (k = 0; k < K_BITS; k = k + 1)
                        if (($random(seed) & 7) == 0)
                            b_vals[c][k] = (($random(seed) & 7) + 1);
                if (count_matches(0) <= LANES)
                    attempts = 100;
            end
        end
    endtask

    task reset_dut;
        begin
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
        end
    endtask

    reg [15:0] big_a [0:3][0:7];
    reg [15:0] big_b [0:7][0:3];

    task init_big_matrices;
        integer m, n, k;
        begin
            for (m = 0; m < 4; m = m + 1)
                for (k = 0; k < 8; k = k + 1)
                    big_a[m][k] = 0;
            for (k = 0; k < 8; k = k + 1)
                for (n = 0; n < 4; n = n + 1)
                    big_b[k][n] = 0;

            big_a[0][1] = 2;  big_a[0][4] = 1;
            big_a[1][3] = 3;  big_a[1][6] = 4;
            big_a[2][0] = 5;  big_a[2][5] = 6;
            big_a[3][2] = 7;  big_a[3][7] = 8;

            big_b[1][0] = 9;  big_b[4][0] = 10;
            big_b[3][1] = 11; big_b[6][1] = 12;
            big_b[0][2] = 13; big_b[5][2] = 14;
            big_b[2][3] = 15; big_b[7][3] = 16;
        end
    endtask

    task load_big_chunk;
        input integer mt;
        input integer nt;
        input integer kc;
        integer r, c, k;
        begin
            clear_current_chunk;
            for (r = 0; r < NUM_ROWS; r = r + 1)
                for (k = 0; k < K_BITS; k = k + 1)
                    a_vals[r][k] = big_a[mt*NUM_ROWS + r][kc*K_BITS + k];
            for (c = 0; c < NUM_COLS; c = c + 1)
                for (k = 0; k < K_BITS; k = k + 1)
                    b_vals[c][k] = big_b[kc*K_BITS + k][nt*NUM_COLS + c];
        end
    endtask

    task check_big_tile;
        input integer mt;
        input integer nt;
        integer r, c, k, exp, idx;
        begin
            for (r = 0; r < NUM_ROWS; r = r + 1) begin
                for (c = 0; c < NUM_COLS; c = c + 1) begin
                    exp = 0;
                    for (k = 0; k < 8; k = k + 1)
                        exp = exp + (big_a[mt*NUM_ROWS + r][k] * big_b[k][nt*NUM_COLS + c]);
                    idx = r * NUM_COLS + c;
                    check_int("big matrix C tile", tile_result_at(idx), exp);
                end
            end
        end
    endtask

    integer t, kc, mt, nt;

    initial begin
        reset_dut;

        $display("\n--- TC1: randomized self-checking K-chunk accumulation ---");
        for (t = 0; t < 8; t = t + 1) begin
            golden_clear;
            for (kc = 0; kc < 3; kc = kc + 1) begin
                make_random_chunk_no_overflow;
                golden_add_current_chunk;
                write_current_chunk;
                run_chunk(kc == 0);
                check_bit("random overflow=0", overflow_seen_o, 1'b0);
            end
            check_against_golden("random final C");
        end

        $display("\n--- TC2: start_i held high for multiple cycles ---");
        clear_current_chunk;
        golden_clear;
        a_vals[0][0] = 3; b_vals[0][0] = 4;
        golden_add_current_chunk;
        write_current_chunk;
        run_chunk_hold_start(1'b1, 3);
        check_int("held-start chunk_count=1", chunk_count_o, 1);
        check_against_golden("held-start final C");

        $display("\n--- TC3: reset during active run clears engine state ---");
        clear_current_chunk;
        a_vals[0][0] = 5; b_vals[0][0] = 6;
        write_current_chunk;
        @(negedge clk);
        start_i = 1'b1;
        clear_accum_i = 1'b1;
        @(posedge clk); #1;
        start_i = 1'b0;
        clear_accum_i = 1'b0;
        @(posedge clk);
        reset = 1'b1;
        repeat (2) @(posedge clk);
        reset = 1'b0;
        #1;
        check_bit("reset busy=0", busy_o, 1'b0);
        check_bit("reset done=0", done_o, 1'b0);
        check_int("reset chunk_count=0", chunk_count_o, 0);
        check_int("reset C00=0", tile_result_at(0), 0);

        $display("\n--- TC4: write same data while compute is active ---");
        clear_current_chunk;
        golden_clear;
        a_vals[0][1] = 2; b_vals[1][1] = 7;
        golden_add_current_chunk;
        write_current_chunk;
        @(negedge clk);
        start_i = 1'b1;
        clear_accum_i = 1'b1;
        @(posedge clk); #1;
        start_i = 1'b0;
        clear_accum_i = 1'b0;
        write_a_fiber(0, 0, mask_a_values(0), pack_a_values(0));
        wait (done_o === 1'b1);
        #1;
        check_against_golden("write-active final C");

        $display("\n--- TC5: overflow detect and manual split replay ---");
        clear_current_chunk;
        a_vals[0][0] = 1; a_vals[0][1] = 1; a_vals[0][2] = 1; a_vals[0][3] = 1;
        a_vals[1][0] = 1; a_vals[1][1] = 1; a_vals[1][2] = 1; a_vals[1][3] = 1;
        b_vals[0][0] = 1; b_vals[0][1] = 1; b_vals[0][2] = 1; b_vals[0][3] = 1;
        write_current_chunk;
        run_chunk(1'b1);
        check_bit("overflow_seen=1", overflow_seen_o, 1'b1);

        golden_clear;
        clear_current_chunk;
        a_vals[0][0] = 1; a_vals[0][1] = 1; a_vals[0][2] = 1; a_vals[0][3] = 1;
        b_vals[0][0] = 1; b_vals[0][1] = 1; b_vals[0][2] = 1; b_vals[0][3] = 1;
        golden_add_current_chunk;
        write_current_chunk;
        run_chunk(1'b1);
        clear_current_chunk;
        a_vals[1][0] = 1; a_vals[1][1] = 1; a_vals[1][2] = 1; a_vals[1][3] = 1;
        b_vals[0][0] = 1; b_vals[0][1] = 1; b_vals[0][2] = 1; b_vals[0][3] = 1;
        golden_add_current_chunk;
        write_current_chunk;
        run_chunk(1'b0);
        check_bit("manual split overflow=0", overflow_seen_o, 1'b0);
        check_against_golden("manual split replay C");

        $display("\n--- TC6: 4x8 by 8x4 matrix loop over M/N/K tiles ---");
        init_big_matrices;
        for (mt = 0; mt < 2; mt = mt + 1) begin
            for (nt = 0; nt < 2; nt = nt + 1) begin
                for (kc = 0; kc < 2; kc = kc + 1) begin
                    load_big_chunk(mt, nt, kc);
                    write_current_chunk;
                    run_chunk(kc == 0);
                end
                check_big_tile(mt, nt);
            end
        end

        $display("\n------------------------------------------");
        $display("tb_trip_tile_regression: %0d passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL PASS"); else $display("SOME FAILURES");
        $display("------------------------------------------");
        $finish;
    end

endmodule

module tb_trip_signed_compute;

    localparam NUM_ROWS = 2;
    localparam NUM_COLS = 2;
    localparam K_BITS = 4;
    localparam LANES = 4;
    localparam DATA_WIDTH = 16;
    localparam ID_WIDTH = 4;
    localparam PRODUCT_WIDTH = DATA_WIDTH * 2;
    localparam ACC_WIDTH = PRODUCT_WIDTH + $clog2(LANES + 1);
    localparam VAL_W = K_BITS * DATA_WIDTH;

    reg clk, reset, start_i;
    reg a_wr_en_i, b_wr_en_i;
    reg [0:0] a_wr_addr_i, b_wr_addr_i;
    reg [ID_WIDTH-1:0] a_wr_id_i, b_wr_id_i;
    reg [K_BITS-1:0] a_wr_mask_i, b_wr_mask_i;
    reg [VAL_W-1:0] a_wr_values_i, b_wr_values_i;
    wire done_o, overflow_o;
    wire [3:0] result_valid_o;
    wire [4*ACC_WIDTH-1:0] result_o;
    wire [2:0] match_count_o;
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    trip_compute_top #(
        .NUM_ROWS(2), .NUM_COLS(2), .K_BITS(4), .LANES(4),
        .DATA_WIDTH(DATA_WIDTH), .ID_WIDTH(ID_WIDTH), .SIGNED_DATA(1)
    ) dut (
        .clk(clk), .reset(reset),
        .a_wr_en_i(a_wr_en_i), .a_wr_addr_i(a_wr_addr_i), .a_wr_id_i(a_wr_id_i),
        .a_wr_mask_i(a_wr_mask_i), .a_wr_values_i(a_wr_values_i),
        .b_wr_en_i(b_wr_en_i), .b_wr_addr_i(b_wr_addr_i), .b_wr_id_i(b_wr_id_i),
        .b_wr_mask_i(b_wr_mask_i), .b_wr_values_i(b_wr_values_i),
        .start_i(start_i), .done_o(done_o),
        .result_valid_o(result_valid_o), .result_o(result_o),
        .match_count_o(match_count_o), .overflow_o(overflow_o)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    function signed [ACC_WIDTH-1:0] result_at;
        input integer idx;
        begin
            result_at = result_o[idx*ACC_WIDTH +: ACC_WIDTH];
        end
    endfunction

    task check_signed;
        input [255:0] label;
        input integer got;
        input integer exp;
        begin
            if (got == exp) begin
                $display("PASS  %s (%0d)", label, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL  %s got=%0d exp=%0d", label, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task write_a;
        input [0:0] addr;
        input [3:0] mask;
        input [VAL_W-1:0] values;
        begin
            @(negedge clk);
            a_wr_en_i = 1'b1; a_wr_addr_i = addr; a_wr_id_i = addr;
            a_wr_mask_i = mask; a_wr_values_i = values;
            @(posedge clk); #1; a_wr_en_i = 1'b0;
        end
    endtask

    task write_b;
        input [0:0] addr;
        input [3:0] mask;
        input [VAL_W-1:0] values;
        begin
            @(negedge clk);
            b_wr_en_i = 1'b1; b_wr_addr_i = addr; b_wr_id_i = addr;
            b_wr_mask_i = mask; b_wr_values_i = values;
            @(posedge clk); #1; b_wr_en_i = 1'b0;
        end
    endtask

    initial begin
        reset = 1'b1; start_i = 1'b0; a_wr_en_i = 1'b0; b_wr_en_i = 1'b0;
        a_wr_addr_i = 0; b_wr_addr_i = 0; a_wr_id_i = 0; b_wr_id_i = 0;
        a_wr_mask_i = 0; b_wr_mask_i = 0; a_wr_values_i = 0; b_wr_values_i = 0;
        repeat (3) @(posedge clk);
        @(negedge clk); reset = 1'b0;

        // C00 = (-2)*3 + 4*(-5) = -26.
        // C11 = (-7)*(-8) = 56.
        write_a(0, 4'b0011, {16'sd0, 16'sd0, 16'sd4, -16'sd2});
        write_a(1, 4'b1000, {-16'sd7, 16'sd0, 16'sd0, 16'sd0});
        write_b(0, 4'b0011, {16'sd0, 16'sd0, -16'sd5, 16'sd3});
        write_b(1, 4'b1000, {-16'sd8, 16'sd0, 16'sd0, 16'sd0});

        @(negedge clk); start_i = 1'b1;
        @(posedge clk); #1; start_i = 1'b0;
        repeat (5) @(posedge clk); #1;

        check_signed("signed C00", result_at(0), -26);
        check_signed("signed C11", result_at(3), 56);
        check_signed("signed match_count", match_count_o, 3);

        $display("\n------------------------------------------");
        $display("tb_trip_signed_compute: %0d passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL PASS"); else $display("SOME FAILURES");
        $display("------------------------------------------");
        $finish;
    end

endmodule

module tb_trip_param_shapes;

    reg clk, reset;
    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // 1x1, K=1, LANES=1 edge case.
    reg s_start, s_a_we, s_b_we;
    reg [3:0] s_a_id, s_b_id;
    reg s_a_mask, s_b_mask;
    reg [15:0] s_a_val, s_b_val;
    wire s_done, s_overflow;
    wire s_valid;
    wire [32:0] s_result;
    wire [0:0] s_count;

    trip_compute_top #(
        .NUM_ROWS(1), .NUM_COLS(1), .K_BITS(1), .LANES(1),
        .DATA_WIDTH(16), .ID_WIDTH(4)
    ) small_dut (
        .clk(clk), .reset(reset),
        .a_wr_en_i(s_a_we), .a_wr_addr_i(1'b0), .a_wr_id_i(s_a_id),
        .a_wr_mask_i(s_a_mask), .a_wr_values_i(s_a_val),
        .b_wr_en_i(s_b_we), .b_wr_addr_i(1'b0), .b_wr_id_i(s_b_id),
        .b_wr_mask_i(s_b_mask), .b_wr_values_i(s_b_val),
        .start_i(s_start), .done_o(s_done),
        .result_valid_o(s_valid), .result_o(s_result),
        .match_count_o(s_count), .overflow_o(s_overflow)
    );

    // 4x4, K=8, LANES=8 non-default shape.
    localparam BW_ACC = 32 + $clog2(8 + 1);
    reg b_start, b_a_we, b_b_we;
    reg [1:0] b_a_addr, b_b_addr;
    reg [3:0] b_a_id, b_b_id;
    reg [7:0] b_a_mask, b_b_mask;
    reg [8*16-1:0] b_a_values, b_b_values;
    wire b_done, b_overflow;
    wire [15:0] b_valid;
    wire [16*BW_ACC-1:0] b_result;
    wire [$clog2(8+1)-1:0] b_count;

    trip_compute_top #(
        .NUM_ROWS(4), .NUM_COLS(4), .K_BITS(8), .LANES(8),
        .DATA_WIDTH(16), .ID_WIDTH(4)
    ) big_dut (
        .clk(clk), .reset(reset),
        .a_wr_en_i(b_a_we), .a_wr_addr_i(b_a_addr), .a_wr_id_i(b_a_id),
        .a_wr_mask_i(b_a_mask), .a_wr_values_i(b_a_values),
        .b_wr_en_i(b_b_we), .b_wr_addr_i(b_b_addr), .b_wr_id_i(b_b_id),
        .b_wr_mask_i(b_b_mask), .b_wr_values_i(b_b_values),
        .start_i(b_start), .done_o(b_done),
        .result_valid_o(b_valid), .result_o(b_result),
        .match_count_o(b_count), .overflow_o(b_overflow)
    );

    function [BW_ACC-1:0] big_result_at;
        input integer idx;
        begin
            big_result_at = b_result[idx*BW_ACC +: BW_ACC];
        end
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

    integer i;
    initial begin
        reset = 1'b1;
        s_start = 0; s_a_we = 0; s_b_we = 0; s_a_id = 0; s_b_id = 0;
        s_a_mask = 0; s_b_mask = 0; s_a_val = 0; s_b_val = 0;
        b_start = 0; b_a_we = 0; b_b_we = 0; b_a_addr = 0; b_b_addr = 0;
        b_a_id = 0; b_b_id = 0; b_a_mask = 0; b_b_mask = 0;
        b_a_values = 0; b_b_values = 0;
        repeat (3) @(posedge clk);
        @(negedge clk); reset = 1'b0;

        @(negedge clk);
        s_a_we = 1; s_a_mask = 1'b1; s_a_val = 16'd6;
        @(posedge clk); #1; s_a_we = 0;
        @(negedge clk);
        s_b_we = 1; s_b_mask = 1'b1; s_b_val = 16'd7;
        @(posedge clk); #1; s_b_we = 0;
        @(negedge clk); s_start = 1'b1;
        @(posedge clk); #1; s_start = 1'b0;
        repeat (5) @(posedge clk); #1;
        check_int("1x1 K1 result", s_result, 42);
        check_int("1x1 K1 valid", s_valid, 1);

        for (i = 0; i < 4; i = i + 1) begin
            @(negedge clk);
            b_a_we = 1'b1;
            b_a_addr = i[1:0];
            b_a_id = i[3:0];
            b_a_mask = 8'b0000_0001 << i;
            b_a_values = {8{16'd0}};
            b_a_values[i*16 +: 16] = i + 2;
            @(posedge clk); #1; b_a_we = 1'b0;

            @(negedge clk);
            b_b_we = 1'b1;
            b_b_addr = i[1:0];
            b_b_id = i[3:0];
            b_b_mask = 8'b0000_0001 << i;
            b_b_values = {8{16'd0}};
            b_b_values[i*16 +: 16] = i + 3;
            @(posedge clk); #1; b_b_we = 1'b0;
        end

        @(negedge clk); b_start = 1'b1;
        @(posedge clk); #1; b_start = 1'b0;
        repeat (8) @(posedge clk); #1;
        check_int("4x4 K8 match_count", b_count, 4);
        check_int("4x4 K8 C00", big_result_at(0), 6);
        check_int("4x4 K8 C05", big_result_at(5), 12);
        check_int("4x4 K8 C10", big_result_at(10), 20);
        check_int("4x4 K8 C15", big_result_at(15), 30);

        $display("\n------------------------------------------");
        $display("tb_trip_param_shapes: %0d passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL PASS"); else $display("SOME FAILURES");
        $display("------------------------------------------");
        $finish;
    end

endmodule
