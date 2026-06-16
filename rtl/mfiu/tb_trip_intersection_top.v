`timescale 1ns/1ps

// Testbench for trip_intersection_top.v
//
// Flow for each test case:
//   1. write_a_fiber / write_b_fiber — load masks into buffers
//   2. run_intersection              — assert start_i, wait for done_o (3 cycles)
//   3. check_*                       — sample MFIU outputs while done_o = 1
//
// Timing (NUM_ROWS = NUM_COLS = 2):
//   negedge   : start_i = 1
//   posedge T : FSM IDLE→S_READ         (start_i sampled)
//   posedge T+1 : S_READ  capture mask[0]
//   posedge T+2 : S_READ  capture mask[1]
//   posedge T+3 : S_DONE  done_o = 1    ← task exits here + #1

module tb_trip_intersection_top;

    // ── Parameters (must match DUT defaults) ─────────────────────────────────
    localparam NUM_ROWS   = 2;
    localparam NUM_COLS   = 2;
    localparam K_BITS     = 4;
    localparam LANES      = 4;
    localparam DATA_WIDTH = 16;
    localparam ID_WIDTH   = 4;
    localparam ADDR_W_A   = 1;   // clog2(2)
    localparam ADDR_W_B   = 1;
    localparam ROW_IDX_W  = 1;
    localparam COL_IDX_W  = 1;
    localparam K_IDX_W    = 2;   // clog2(4)
    localparam CNT_W      = 3;   // clog2(5)
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
    wire                        overflow_o;

    // ── DUT instantiation ─────────────────────────────────────────────────────
    trip_intersection_top #(
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
        .done_o         (done_o),
        .lane_valid_o   (lane_valid_o),
        .a_row_sel_o    (a_row_sel_o),
        .b_col_sel_o    (b_col_sel_o),
        .k_sel_o        (k_sel_o),
        .match_count_o  (match_count_o),
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
    // For MAX_FIBERS=2: done_o arrives exactly 3 posedges after start_i is sampled.
    task run_intersection;
        integer i;
        begin
            @(negedge clk); start_i = 1;
            @(posedge clk); #1;   // posedge T: FSM IDLE → S_READ
            start_i = 0;
            // Wait MAX_FIBERS read cycles + 1 DONE cycle
            for (i = 0; i < MAX_FIBERS + 1; i = i + 1)
                @(posedge clk);
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
        //   Scan order (r,c, k low→high):
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
        check    ("TC1 lane_valid=4'b1111", lane_valid_o,  4'b1111);
        check_int("TC1 match_count=4    ", match_count_o, 4);
        check    ("TC1 overflow=0        ", overflow_o,    1'b0);
        check_lane("TC1 lane0 (0,0,3)", 0, 0, 0, 3);
        check_lane("TC1 lane1 (0,1,1)", 1, 0, 1, 1);
        check_lane("TC1 lane2 (0,1,3)", 2, 0, 1, 3);
        check_lane("TC1 lane3 (1,1,1)", 3, 1, 1, 1);

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

        check    ("TC2 lane_valid=0      ", lane_valid_o, 4'b0000);
        check_int("TC2 match_count=0    ", match_count_o, 0);
        check    ("TC2 overflow=0        ", overflow_o, 1'b0);

        // =============================================================
        // TC3  Overflow — 8 effectual MACs but LANES = 4
        //   A0=4'b1111, A1=4'b1111, B0=4'b1111, B1=4'b0000
        //   pair(0,0): 4 hits, pair(1,0): 4 hits → total 8 > 4
        // =============================================================
        $display("\n--- TC3: overflow ---");
        write_a_fiber(0, 0, 4'b1111, {VAL_W{1'b0}});
        write_a_fiber(1, 1, 4'b1111, {VAL_W{1'b0}});
        write_b_fiber(0, 0, 4'b1111, {VAL_W{1'b0}});
        write_b_fiber(1, 1, 4'b0000, {VAL_W{1'b0}});
        run_intersection;

        check_int("TC3 match_count=4 (capped)", match_count_o, 4);
        check    ("TC3 overflow=1            ", overflow_o, 1'b1);
        check    ("TC3 all 4 lanes valid     ", lane_valid_o, 4'b1111);

        // =============================================================
        // TC4  Overwrite then re-run — single k=0 hit per pair
        //   A0=4'b0001, A1=4'b0001, B0=4'b0001, B1=4'b0001
        //   All 4 pairs intersect only at k=0 → 4 MACs at k=0
        //   Scan order: (0,0,0), (0,1,0), (1,0,0), (1,1,0)
        // =============================================================
        $display("\n--- TC4: overwrite buffers, k=0 only ---");
        write_a_fiber(0, 2, 4'b0001, {VAL_W{1'b0}});
        write_a_fiber(1, 3, 4'b0001, {VAL_W{1'b0}});
        write_b_fiber(0, 2, 4'b0001, {VAL_W{1'b0}});
        write_b_fiber(1, 3, 4'b0001, {VAL_W{1'b0}});
        run_intersection;

        check_int("TC4 match_count=4    ", match_count_o, 4);
        check    ("TC4 overflow=0        ", overflow_o, 1'b0);
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
