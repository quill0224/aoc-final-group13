`timescale 1ns/1ps

// Testbench for trip_intersection_top.v
//
// Flow for each test case:
//   1. write_a_fiber / write_b_fiber — load masks into buffers
//   2. run_intersection              — assert start_i, wait for done_o
//   3. check_*                       — sample MFIU outputs while done_o = 1
//
// Timing (NUM_ROWS = NUM_COLS = 2):
//   negedge   : start_i = 1
//   posedge T : FSM IDLE→S_READ         (start_i sampled)
//   posedge T+1 : S_READ  capture mask[0]
//   posedge T+2 : S_READ  capture mask[1]
// Packed MFIU mode adds pipeline cycles; the task waits for done_o.

module tb_trip_intersection_top;

    // ── Parameters (must match DUT defaults) ─────────────────────────────────
    localparam NUM_ROWS   = 2;
    localparam NUM_COLS   = 2;
    localparam K_BITS     = 4;
    localparam LANES      = 16;
    localparam DATA_WIDTH = 16;
    localparam ID_WIDTH   = 4;
    localparam ADDR_W_A   = 1;   // clog2(2)
    localparam ADDR_W_B   = 1;
    localparam ROW_IDX_W  = 1;
    localparam COL_IDX_W  = 1;
    localparam K_IDX_W    = 2;   // clog2(4)
    localparam CNT_W      = 5;   // clog2(17)
    localparam MAX_FIBERS = 2;
    localparam VAL_W      = K_BITS * DATA_WIDTH;   // 64

    // ── DUT ports ─────────────────────────────────────────────────────────────
    reg  clk, reset, start_i;
    reg  a_wr_en_i, b_wr_en_i;
    reg  [ADDR_W_A-1:0]  a_wr_addr_i;
    reg  [ADDR_W_B-1:0]  b_wr_addr_i;
    reg  [ID_WIDTH-1:0]  a_wr_id_i,    b_wr_id_i;
    reg  [K_BITS-1:0]    a_wr_mask_i,  b_wr_mask_i;
    reg  [VAL_W-1:0]     a_wr_values_i, b_wr_values_i;

    wire                        done_o;
    wire [LANES-1:0]            lane_valid_o;
    wire [LANES*ROW_IDX_W-1:0] a_row_sel_o;
    wire [LANES*COL_IDX_W-1:0] b_col_sel_o;
    wire [LANES*K_IDX_W-1:0]   k_sel_o;
    wire [CNT_W-1:0]            match_count_o;
    wire [1:0]                  active_b_cols_o;
    wire                        overflow_o;

    // ── DUT instantiation ─────────────────────────────────────────────────────
    trip_intersection_top #(
        .NUM_ROWS   (NUM_ROWS),
        .NUM_COLS   (NUM_COLS),
        .K_BITS     (K_BITS),
        .LANES      (LANES),
        .DATA_WIDTH (DATA_WIDTH),
        .ID_WIDTH   (ID_WIDTH),
        .PACKED_MFIU(1)
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
        .done_o         (done_o),
        .lane_valid_o   (lane_valid_o),
        .a_row_sel_o    (a_row_sel_o),
        .b_col_sel_o    (b_col_sel_o),
        .k_sel_o        (k_sel_o),
        .match_count_o  (match_count_o),
        .active_b_cols_o(active_b_cols_o),
        .overflow_o     (overflow_o)
    );

    // ── Clock (10 ns period) ──────────────────────────────────────────────────
    initial clk = 0;
    always #5 clk = ~clk;

    // ── Scoreboard ────────────────────────────────────────────────────────────
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // ── Extract one index from a packed lane array ────────────────────────────
    function [ROW_IDX_W-1:0] get_row;
        input [LANES*ROW_IDX_W-1:0] arr;
        input integer lane;
        get_row = arr[lane*ROW_IDX_W +: ROW_IDX_W];
    endfunction

    function [COL_IDX_W-1:0] get_col;
        input [LANES*COL_IDX_W-1:0] arr;
        input integer lane;
        get_col = arr[lane*COL_IDX_W +: COL_IDX_W];
    endfunction

    function [K_IDX_W-1:0] get_k;
        input [LANES*K_IDX_W-1:0] arr;
        input integer lane;
        get_k = arr[lane*K_IDX_W +: K_IDX_W];
    endfunction

    // ── Check helpers ─────────────────────────────────────────────────────────
    task check;
        input [199:0] label;
        input         got;
        input         exp;
        begin
            if (got === exp) begin
                $display("PASS  %s", label);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL  %s  got=%0b exp=%0b", label, got, exp);
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
                $display("PASS  %s  (%0d)", label, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL  %s  got=%0d exp=%0d", label, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // Verify one lane's (row, col, k) triple
    task check_lane;
        input [199:0] prefix;
        input integer lane;
        input integer exp_row, exp_col, exp_k;
        begin
            check_int({prefix, " row"}, get_row(a_row_sel_o, lane), exp_row);
            check_int({prefix, " col"}, get_col(b_col_sel_o, lane), exp_col);
            check_int({prefix, " k  "}, get_k  (k_sel_o,     lane), exp_k);
        end
    endtask

    // ── Write tasks (1 posedge per fiber) ────────────────────────────────────
    task write_a_fiber;
        input [ADDR_W_A-1:0] addr;
        input [ID_WIDTH-1:0] id;
        input [K_BITS-1:0]   mask;
        input [VAL_W-1:0]    values;
        begin
            @(negedge clk);
            a_wr_en_i     = 1;
            a_wr_addr_i   = addr;
            a_wr_id_i     = id;
            a_wr_mask_i   = mask;
            a_wr_values_i = values;
            @(posedge clk); #1;
            a_wr_en_i = 0;
        end
    endtask

    task write_b_fiber;
        input [ADDR_W_B-1:0] addr;
        input [ID_WIDTH-1:0] id;
        input [K_BITS-1:0]   mask;
        input [VAL_W-1:0]    values;
        begin
            @(negedge clk);
            b_wr_en_i     = 1;
            b_wr_addr_i   = addr;
            b_wr_id_i     = id;
            b_wr_mask_i   = mask;
            b_wr_values_i = values;
            @(posedge clk); #1;
            b_wr_en_i = 0;
        end
    endtask

    // Assert start_i for one cycle, then wait for done_o.
    task run_intersection;
        begin
            @(negedge clk); start_i = 1;
            @(posedge clk); #1;   // posedge T: FSM IDLE → S_READ
            start_i = 0;
            wait(done_o === 1'b1);
            #1;   // settle after final posedge — done_o is now stable
        end
    endtask

    // ── Test cases ────────────────────────────────────────────────────────────
    initial begin
        // Initialise
        {reset, start_i}              = 2'b10;
        {a_wr_en_i, b_wr_en_i}       = 2'b00;
        {a_wr_addr_i, b_wr_addr_i}   = '0;
        {a_wr_id_i,   b_wr_id_i}     = '0;
        {a_wr_mask_i, b_wr_mask_i}   = '0;
        {a_wr_values_i, b_wr_values_i} = '0;

        repeat(3) @(posedge clk);
        @(negedge clk); reset = 0;

        // =============================================================
        // TC1  §29 worked example — 4 effectual MACs, no overflow
        //
        //   A0=4'b1010  A1=4'b0110
        //   B0=4'b1001  B1=4'b1010
        //
        //   pair(0,0): A0 & B0 = 1000 → k3
        //   pair(0,1): A0 & B1 = 1010 → k1, k3
        //   pair(1,0): A1 & B0 = 0000 → (none)
        //   pair(1,1): A1 & B1 = 0010 → k1
        //
        //   Packed mapping:
        //     lane0 ← (0,0,k3)
        //     lane1 ← (0,1,k1)
        //     lane2 ← (0,1,k3)
        //     lane3 ← (1,1,k1)
        // =============================================================
        $display("\n--- TC1: S29 worked example ---");
        write_a_fiber(0, 0, 4'b1010, {VAL_W{1'b0}});
        write_a_fiber(1, 1, 4'b0110, {VAL_W{1'b0}});
        write_b_fiber(0, 0, 4'b1001, {VAL_W{1'b0}});
        write_b_fiber(1, 1, 4'b1010, {VAL_W{1'b0}});
        run_intersection;

        check    ("TC1 done_o=1          ", done_o,        1'b1);
        check_int("TC1 lane_valid bitmap", lane_valid_o,  16'h000f);
        check_int("TC1 match_count=4    ", match_count_o, 4);
        check_int("TC1 active_cols=2    ", active_b_cols_o, 2);
        check    ("TC1 overflow=0        ", overflow_o,    1'b0);
        check_lane("TC1 lane0  (0,0,3)", 0, 0, 0, 3);
        check_lane("TC1 lane1  (0,1,1)", 1, 0, 1, 1);
        check_lane("TC1 lane2  (0,1,3)", 2, 0, 1, 3);
        check_lane("TC1 lane3  (1,1,1)", 3, 1, 1, 1);

        // =============================================================
        // TC2  No intersection — complementary masks
        //   A0=4'b1010, A1=4'b1010, B0=4'b0101, B1=4'b0101
        //   All pairwise ANDs = 0 → no effectual MACs
        // =============================================================
        $display("\n--- TC2: no intersection ---");
        write_a_fiber(0, 0, 4'b1010, {VAL_W{1'b0}});
        write_a_fiber(1, 1, 4'b1010, {VAL_W{1'b0}});
        write_b_fiber(0, 0, 4'b0101, {VAL_W{1'b0}});
        write_b_fiber(1, 1, 4'b0101, {VAL_W{1'b0}});
        run_intersection;

        check_int("TC2 lane_valid=0     ", lane_valid_o, 16'h0000);
        check_int("TC2 match_count=0    ", match_count_o, 0);
        check    ("TC2 overflow=0        ", overflow_o, 1'b0);

        // =============================================================
        // TC3  8 effectual MACs in direct-mapped lanes
        //   A0=4'b1111, A1=4'b1111, B0=4'b1111, B1=4'b0000
        //   pair(0,0): 4 hits, pair(1,0): 4 hits
        // =============================================================
        $display("\n--- TC3: 8 direct-mapped hits ---");
        write_a_fiber(0, 0, 4'b1111, {VAL_W{1'b0}});
        write_a_fiber(1, 1, 4'b1111, {VAL_W{1'b0}});
        write_b_fiber(0, 0, 4'b1111, {VAL_W{1'b0}});
        write_b_fiber(1, 1, 4'b0000, {VAL_W{1'b0}});
        run_intersection;

        check_int("TC3 match_count=8        ", match_count_o, 8);
        check    ("TC3 overflow=0            ", overflow_o, 1'b0);
        check_int("TC3 valid bitmap          ", lane_valid_o, 16'h00ff);

        // =============================================================
        // TC4  Overwrite then re-run — single k=0 hit per pair
        //   A0=4'b0001, A1=4'b0001, B0=4'b0001, B1=4'b0001
        //   All 4 pairs intersect only at k=0 → 4 MACs at k=0
        //   Packed lanes: 0, 1, 2, 3
        // =============================================================
        $display("\n--- TC4: overwrite buffers, k=0 only ---");
        write_a_fiber(0, 2, 4'b0001, {VAL_W{1'b0}});
        write_a_fiber(1, 3, 4'b0001, {VAL_W{1'b0}});
        write_b_fiber(0, 2, 4'b0001, {VAL_W{1'b0}});
        write_b_fiber(1, 3, 4'b0001, {VAL_W{1'b0}});
        run_intersection;

        check_int("TC4 match_count=4    ", match_count_o, 4);
        check    ("TC4 overflow=0        ", overflow_o, 1'b0);
        check_int("TC4 valid bitmap      ", lane_valid_o, 16'h000f);
        check_lane("TC4 lane0 (0,0,0)", 0, 0, 0, 0);
        check_lane("TC4 lane1 (0,1,0)", 1, 0, 1, 0);
        check_lane("TC4 lane2 (1,0,0)", 2, 1, 0, 0);
        check_lane("TC4 lane3 (1,1,0)", 3, 1, 1, 0);

        // =============================================================
        // TC5  Consecutive runs — second run immediately after first
        //      (no write between runs; same fiber data; result must match TC4)
        // =============================================================
        $display("\n--- TC5: consecutive run (same fibers as TC4) ---");
        run_intersection;

        check_int("TC5 match_count=4    ", match_count_o, 4);
        check    ("TC5 overflow=0        ", overflow_o, 1'b0);
        check_int("TC5 valid bitmap      ", lane_valid_o, 16'h000f);
        check_lane("TC5 lane0 (0,0,0)", 0, 0, 0, 0);
        check_lane("TC5 lane3 (1,1,0)", 3, 1, 1, 0);

        // ── Summary ───────────────────────────────────────────────────────────
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

// ── tb_trip_intersection_overflow: overflow / active_b_cols test ─────────────
// Config: NUM_ROWS=2, NUM_COLS=2, K_BITS=4, LANES=6 (easy overflow trigger)
// Run with: iverilog -g2012 -s tb_trip_intersection_overflow ...

module tb_trip_overflow;

    // ── DUT parameters ────────────────────────────────────────────────────────
    localparam NUM_ROWS   = 2;
    localparam NUM_COLS   = 2;
    localparam K_BITS     = 4;
    localparam LANES      = 6;
    localparam DATA_WIDTH = 8;
    localparam ID_WIDTH   = 4;
    localparam GROUPS     = 4;   // TOTAL_CANDIDATES=16 divisible by 4 → G_SIZE=4

    localparam ROW_IDX_W     = $clog2(NUM_ROWS);   // =1
    localparam COL_IDX_W     = $clog2(NUM_COLS);   // =1
    localparam K_IDX_W       = $clog2(K_BITS);     // =2
    localparam ACTIVE_COLS_W = $clog2(NUM_COLS+1); // =2
    localparam CNT_W         = $clog2(LANES+1);    // =3
    localparam ADDR_W_A      = $clog2(NUM_ROWS);   // =1
    localparam ADDR_W_B      = $clog2(NUM_COLS);   // =1

    // ── Clock / reset ─────────────────────────────────────────────────────────
    reg clk = 0;
    always #5 clk = ~clk;

    reg reset;

    // ── DUT ports ─────────────────────────────────────────────────────────────
    reg                             a_wr_en;
    reg  [ADDR_W_A-1:0]            a_wr_addr;
    reg  [ID_WIDTH-1:0]            a_wr_id;
    reg  [K_BITS-1:0]             a_wr_mask;
    reg  [K_BITS*DATA_WIDTH-1:0]  a_wr_values;

    reg                             b_wr_en;
    reg  [ADDR_W_B-1:0]            b_wr_addr;
    reg  [ID_WIDTH-1:0]            b_wr_id;
    reg  [K_BITS-1:0]             b_wr_mask;
    reg  [K_BITS*DATA_WIDTH-1:0]  b_wr_values;

    reg  start;
    wire done;

    wire [LANES-1:0]              lane_valid;
    wire [LANES*ROW_IDX_W-1:0]   a_row_sel;
    wire [LANES*COL_IDX_W-1:0]   b_col_sel;
    wire [LANES*K_IDX_W-1:0]     k_sel;
    wire [CNT_W-1:0]             match_count;
    wire [ACTIVE_COLS_W-1:0]     active_b_cols;
    wire                          overflow;

    wire [NUM_ROWS*K_BITS*DATA_WIDTH-1:0] a_values;
    wire [NUM_COLS*K_BITS*DATA_WIDTH-1:0] b_values;

    // ── DUT instantiation ─────────────────────────────────────────────────────
    trip_intersection_top #(
        .NUM_ROWS    (NUM_ROWS),
        .NUM_COLS    (NUM_COLS),
        .K_BITS      (K_BITS),
        .LANES       (LANES),
        .DATA_WIDTH  (DATA_WIDTH),
        .ID_WIDTH    (ID_WIDTH),
        .PACKED_MFIU (1)
    ) dut (
        .clk              (clk),
        .reset            (reset),
        .a_wr_en_i        (a_wr_en),
        .a_wr_addr_i      (a_wr_addr),
        .a_wr_id_i        (a_wr_id),
        .a_wr_mask_i      (a_wr_mask),
        .a_wr_values_i    (a_wr_values),
        .b_wr_en_i        (b_wr_en),
        .b_wr_addr_i      (b_wr_addr),
        .b_wr_id_i        (b_wr_id),
        .b_wr_mask_i      (b_wr_mask),
        .b_wr_values_i    (b_wr_values),
        .start_i          (start),
        .done_o           (done),
        .lane_valid_o     (lane_valid),
        .a_row_sel_o      (a_row_sel),
        .b_col_sel_o      (b_col_sel),
        .k_sel_o          (k_sel),
        .match_count_o    (match_count),
        .active_b_cols_o  (active_b_cols),
        .overflow_o       (overflow),
        .a_values_o       (a_values),
        .b_values_o       (b_values)
    );

    // ── Checker helpers ───────────────────────────────────────────────────────
    integer pass_cnt = 0, fail_cnt = 0;

    task check;
        input [63:0] got;
        input [63:0] exp;
        input [255:0] label;
        begin
            if (got === exp) begin
                $display("PASS  %s (%0d)", label, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL  %s: got %0d, exp %0d", label, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task check_lane;
        input integer lane;
        input [ROW_IDX_W-1:0] exp_row;
        input [COL_IDX_W-1:0] exp_col;
        input [K_IDX_W-1:0]   exp_k;
        reg [ROW_IDX_W-1:0] got_row;
        reg [COL_IDX_W-1:0] got_col;
        reg [K_IDX_W-1:0]   got_k;
        begin
            got_row = a_row_sel[lane*ROW_IDX_W +: ROW_IDX_W];
            got_col = b_col_sel[lane*COL_IDX_W +: COL_IDX_W];
            got_k   = k_sel    [lane*K_IDX_W   +: K_IDX_W  ];
            if (got_row === exp_row && got_col === exp_col && got_k === exp_k) begin
                $display("PASS  lane%0d (%0d,%0d,k=%0d)", lane, exp_row, exp_col, exp_k);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL  lane%0d: got (%0d,%0d,k=%0d) exp (%0d,%0d,k=%0d)",
                         lane, got_row, got_col, got_k, exp_row, exp_col, exp_k);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ── Write one A fiber into the bitmask_buffer ─────────────────────────────
    task write_a_fiber;
        input [ADDR_W_A-1:0]           addr;
        input [K_BITS-1:0]            mask;
        input [K_BITS*DATA_WIDTH-1:0] vals;
        begin
            @(negedge clk);
            a_wr_en     = 1; a_wr_addr = addr; a_wr_id = 0;
            a_wr_mask   = mask; a_wr_values = vals;
            @(negedge clk);
            a_wr_en = 0;
        end
    endtask

    task write_b_fiber;
        input [ADDR_W_B-1:0]           addr;
        input [K_BITS-1:0]            mask;
        input [K_BITS*DATA_WIDTH-1:0] vals;
        begin
            @(negedge clk);
            b_wr_en     = 1; b_wr_addr = addr; b_wr_id = 0;
            b_wr_mask   = mask; b_wr_values = vals;
            @(negedge clk);
            b_wr_en = 0;
        end
    endtask

    // ── Run one intersection and capture results ───────────────────────────────
    task run_and_wait;
        begin
            @(negedge clk);
            start = 1;
            @(negedge clk);
            start = 0;
            // Wait for done pulse (timeout after 100 cycles)
            begin : wait_block
                integer cyc;
                for (cyc = 0; cyc < 100; cyc = cyc + 1) begin
                    @(posedge clk);
                    if (done) disable wait_block;
                end
                $display("TIMEOUT waiting for done_o");
                fail_cnt = fail_cnt + 1;
            end
            @(negedge clk); // settle outputs
        end
    endtask

    // ── Main stimulus ─────────────────────────────────────────────────────────
    initial begin
        // Initialize
        {a_wr_en, b_wr_en, start} = 0;
        {a_wr_addr, b_wr_addr}   = 0;
        {a_wr_id, b_wr_id}       = 0;
        {a_wr_mask, b_wr_mask}   = 0;
        {a_wr_values, b_wr_values} = 0;

        reset = 1;
        repeat (4) @(posedge clk);
        @(negedge clk); reset = 0;
        repeat (2) @(posedge clk);

        // ─── TC1: all-ones masks → overflow ─────────────────────────────────
        // col_cnt[0]=8 > LANES=6 → overflow_o=1, active_b_cols_o=1
        // Only 6 events placed (rows 0..1 × col 0 × k=0..1 for row 1 dropped)
        $display("--- TC1: all-ones masks (overflow expected) ---");
        write_a_fiber(0, 4'b1111, {(K_BITS*DATA_WIDTH){1'b0}});
        write_a_fiber(1, 4'b1111, {(K_BITS*DATA_WIDTH){1'b0}});
        write_b_fiber(0, 4'b1111, {(K_BITS*DATA_WIDTH){1'b0}});
        write_b_fiber(1, 4'b1111, {(K_BITS*DATA_WIDTH){1'b0}});

        run_and_wait;

        check(overflow,       1,  "TC1 overflow");
        check(active_b_cols,  1,  "TC1 active_b_cols");
        // lane_valid should be 6'b111111 (all 6 lanes used)
        check(lane_valid,     6'b111111, "TC1 lane_valid");
        // Lanes 0..3: row0 × col0 × k=0..3
        check_lane(0, 0, 0, 0);
        check_lane(1, 0, 0, 1);
        check_lane(2, 0, 0, 2);
        check_lane(3, 0, 0, 3);
        // Lanes 4..5: row1 × col0 × k=0..1 (k=2,3 dropped: lane_idx 6,7 ≥ LANES)
        check_lane(4, 1, 0, 0);
        check_lane(5, 1, 0, 1);

        // ─── TC2: two B cols, 3 events each → exactly LANES, no overflow ────
        // A row 0 = k=0..2 (3 bits), A row 1 = empty
        // B col 0 = k=0..2 (3 bits), B col 1 = k=0..2 (3 bits)
        // col_cnt[0]=3, col_cnt[1]=3 → col_acc[1]=6 ≤ LANES → active_b_cols=2
        $display("--- TC2: two cols, 3 each, exactly LANES (no overflow) ---");
        write_a_fiber(0, 4'b0111, {(K_BITS*DATA_WIDTH){1'b0}});
        write_a_fiber(1, 4'b0000, {(K_BITS*DATA_WIDTH){1'b0}});
        write_b_fiber(0, 4'b0111, {(K_BITS*DATA_WIDTH){1'b0}});
        write_b_fiber(1, 4'b0111, {(K_BITS*DATA_WIDTH){1'b0}});

        run_and_wait;

        check(overflow,      0,  "TC2 overflow");
        check(active_b_cols, 2,  "TC2 active_b_cols");
        check(lane_valid,    6'b111111, "TC2 lane_valid");
        // row0 × col0 × k=0..2 → lanes 0..2
        check_lane(0, 0, 0, 0);
        check_lane(1, 0, 0, 1);
        check_lane(2, 0, 0, 2);
        // row0 × col1 × k=0..2 → lanes 3..5
        check_lane(3, 0, 1, 0);
        check_lane(4, 0, 1, 1);
        check_lane(5, 0, 1, 2);

        // ─── TC3: single sparse B col, 4 events, no overflow ────────────────
        // A row 0 = k=0,1 (2 bits), A row 1 = k=0,1 (2 bits)
        // B col 0 = k=0,1 (2 bits), B col 1 = empty
        // col_cnt[0]=4, col_cnt[1]=0 → col_acc[0]=4 ≤ 6, col_acc[1]=4 ≤ 6
        // active_b_cols=2, overflow=0, match_count=4
        $display("--- TC3: sparse, 4 events, no overflow ---");
        write_a_fiber(0, 4'b0011, {(K_BITS*DATA_WIDTH){1'b0}});
        write_a_fiber(1, 4'b0011, {(K_BITS*DATA_WIDTH){1'b0}});
        write_b_fiber(0, 4'b0011, {(K_BITS*DATA_WIDTH){1'b0}});
        write_b_fiber(1, 4'b0000, {(K_BITS*DATA_WIDTH){1'b0}});

        run_and_wait;

        check(overflow,      0,          "TC3 overflow");
        // col_cnt[0]=4, col_cnt[1]=0 → col_acc[0]=4, col_acc[1]=4 → both ≤ 6
        check(active_b_cols, 2,          "TC3 active_b_cols");
        // 4 events: row0×col0×k0, row0×col0×k1, row1×col0×k0, row1×col0×k1
        check(lane_valid,    6'b001111,  "TC3 lane_valid (lanes 0..3)");
        check_lane(0, 0, 0, 0);
        check_lane(1, 0, 0, 1);
        check_lane(2, 1, 0, 0);
        check_lane(3, 1, 0, 1);

        // ── Summary ──────────────────────────────────────────────────────────
        $display("------------------------------------------");
        $display("Result: %0d passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL PASS");
        else                $display("SOME FAILURES");
        $display("------------------------------------------");
        $finish;
    end

endmodule
