// tb_trip_int_4x4x32.v — trip_intersection_top functional testbench: 4×4/K=32
//
// Paper-aligned parameters: NUM_ROWS=4, NUM_COLS=4, K_BITS=32, LANES=128.
// Complements tb_trip_intersection_top.v (2×2/K=4).
// Instantiates trip_intersection_top with PACKED_MFIU=1, exercises the full
// 5-stage mfiu_pipelined pipeline at production scale.
//
// Golden reference computed from first principles (see tb comments per TC).
//
// TC1: all-zeros masks               → 0 events, all lanes invalid
// TC2: single event (r=0,c=0,k=0)   → lane 0 only
// TC3: dense B col 0, all A rows     → 128 events, all lanes (row=l/32,k=l%32)
// TC4: two sparse B cols (k=0..7)    → 64 events, lanes 0..63
// TC5: consecutive run (TC4 repeat)  → same result

`timescale 1ns/1ps

module tb_trip_int_4x4x32;

    // ── Parameters ────────────────────────────────────────────────────────────
    localparam NUM_ROWS   = 4;
    localparam NUM_COLS   = 4;
    localparam K_BITS     = 32;
    localparam LANES      = 128;
    localparam DATA_WIDTH = 16;
    localparam ID_WIDTH   = 4;

    localparam ROW_IDX_W     = $clog2(NUM_ROWS);       // 2
    localparam COL_IDX_W     = $clog2(NUM_COLS);       // 2
    localparam K_IDX_W       = $clog2(K_BITS);         // 5
    localparam ACTIVE_COLS_W = $clog2(NUM_COLS + 1);   // 3
    localparam CNT_W         = $clog2(LANES + 1);      // 8
    localparam ADDR_W_A      = $clog2(NUM_ROWS);       // 2
    localparam ADDR_W_B      = $clog2(NUM_COLS);       // 2

    // ── Clock / reset ─────────────────────────────────────────────────────────
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset;

    // ── DUT ports ─────────────────────────────────────────────────────────────
    reg                             a_wr_en, b_wr_en;
    reg  [ADDR_W_A-1:0]            a_wr_addr;
    reg  [ADDR_W_B-1:0]            b_wr_addr;
    reg  [ID_WIDTH-1:0]            a_wr_id,  b_wr_id;
    reg  [K_BITS-1:0]             a_wr_mask, b_wr_mask;
    reg  [K_BITS*DATA_WIDTH-1:0]  a_wr_values, b_wr_values;

    reg  start;
    wire done;

    wire [LANES-1:0]              lane_valid;
    wire [LANES*ROW_IDX_W-1:0]   a_row_sel;
    wire [LANES*COL_IDX_W-1:0]   b_col_sel;
    wire [LANES*K_IDX_W-1:0]     k_sel;
    wire [CNT_W-1:0]             match_count;
    wire [ACTIVE_COLS_W-1:0]     active_b_cols;
    wire                          overflow;

    wire [NUM_ROWS*K_BITS*DATA_WIDTH-1:0] a_values_o;
    wire [NUM_COLS*K_BITS*DATA_WIDTH-1:0] b_values_o;

    // ── DUT ──────────────────────────────────────────────────────────────────
    trip_intersection_top #(
        .NUM_ROWS    (NUM_ROWS),
        .NUM_COLS    (NUM_COLS),
        .K_BITS      (K_BITS),
        .LANES       (LANES),
        .DATA_WIDTH  (DATA_WIDTH),
        .ID_WIDTH    (ID_WIDTH),
        .PACKED_MFIU (1)
    ) dut (
        .clk             (clk),
        .reset           (reset),
        .a_wr_en_i       (a_wr_en),
        .a_wr_addr_i     (a_wr_addr),
        .a_wr_id_i       (a_wr_id),
        .a_wr_mask_i     (a_wr_mask),
        .a_wr_values_i   (a_wr_values),
        .b_wr_en_i       (b_wr_en),
        .b_wr_addr_i     (b_wr_addr),
        .b_wr_id_i       (b_wr_id),
        .b_wr_mask_i     (b_wr_mask),
        .b_wr_values_i   (b_wr_values),
        .start_i         (start),
        .done_o          (done),
        .lane_valid_o    (lane_valid),
        .a_row_sel_o     (a_row_sel),
        .b_col_sel_o     (b_col_sel),
        .k_sel_o         (k_sel),
        .match_count_o   (match_count),
        .active_b_cols_o (active_b_cols),
        .overflow_o      (overflow),
        .a_values_o      (a_values_o),
        .b_values_o      (b_values_o)
    );

    // ── Counters / helpers ────────────────────────────────────────────────────
    integer pass_cnt = 0, fail_cnt = 0;
    integer i;

    function [ROW_IDX_W-1:0] get_row;
        input integer lane;
        get_row = a_row_sel[lane*ROW_IDX_W +: ROW_IDX_W];
    endfunction

    function [COL_IDX_W-1:0] get_col;
        input integer lane;
        get_col = b_col_sel[lane*COL_IDX_W +: COL_IDX_W];
    endfunction

    function [K_IDX_W-1:0] get_k;
        input integer lane;
        get_k = k_sel[lane*K_IDX_W +: K_IDX_W];
    endfunction

    task check_int;
        input [255:0] label;
        input integer got, exp;
        begin
            if (got === exp) begin
                $display("PASS  %s (%0d)", label, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL  %s: got=%0d exp=%0d", label, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task check_bit;
        input [255:0] label;
        input got, exp;
        begin
            if (got === exp) begin
                $display("PASS  %s", label);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL  %s: got=%0b exp=%0b", label, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task check_lane;
        input integer lane;
        input integer exp_row, exp_col, exp_k;
        begin
            if (lane_valid[lane] !== 1'b1) begin
                $display("FAIL  lane%0d: not valid", lane);
                fail_cnt = fail_cnt + 1;
            end else if (get_row(lane) !== exp_row[ROW_IDX_W-1:0] ||
                         get_col(lane) !== exp_col[COL_IDX_W-1:0] ||
                         get_k(lane)   !== exp_k[K_IDX_W-1:0]) begin
                $display("FAIL  lane%0d: got (r=%0d,c=%0d,k=%0d) exp (r=%0d,c=%0d,k=%0d)",
                         lane, get_row(lane), get_col(lane), get_k(lane),
                         exp_row, exp_col, exp_k);
                fail_cnt = fail_cnt + 1;
            end else begin
                $display("PASS  lane%0d (r=%0d,c=%0d,k=%0d)", lane, exp_row, exp_col, exp_k);
                pass_cnt = pass_cnt + 1;
            end
        end
    endtask

    // ── Write tasks ───────────────────────────────────────────────────────────
    task write_a;
        input [ADDR_W_A-1:0]           addr;
        input [K_BITS-1:0]            mask;
        input [K_BITS*DATA_WIDTH-1:0] vals;
        begin
            @(negedge clk);
            a_wr_en = 1; a_wr_addr = addr; a_wr_id = 0;
            a_wr_mask = mask; a_wr_values = vals;
            @(negedge clk);
            a_wr_en = 0;
        end
    endtask

    task write_b;
        input [ADDR_W_B-1:0]           addr;
        input [K_BITS-1:0]            mask;
        input [K_BITS*DATA_WIDTH-1:0] vals;
        begin
            @(negedge clk);
            b_wr_en = 1; b_wr_addr = addr; b_wr_id = 0;
            b_wr_mask = mask; b_wr_values = vals;
            @(negedge clk);
            b_wr_en = 0;
        end
    endtask

    task run_and_wait;
        begin
            @(negedge clk); start = 1;
            @(negedge clk); start = 0;
            begin : wait_done
                integer cyc;
                for (cyc = 0; cyc < 200; cyc = cyc + 1) begin
                    @(posedge clk);
                    if (done) disable wait_done;
                end
                $display("TIMEOUT waiting for done_o");
                fail_cnt = fail_cnt + 1;
            end
            @(negedge clk);  // settle
        end
    endtask

    // ── Stimulus ──────────────────────────────────────────────────────────────
    initial begin
        {a_wr_en, b_wr_en, start} = 0;
        a_wr_addr = 0; b_wr_addr = 0;
        a_wr_id = 0; b_wr_id = 0;
        a_wr_mask = 0; b_wr_mask = 0;
        a_wr_values = 0; b_wr_values = 0;

        reset = 1;
        repeat (4) @(posedge clk);
        @(negedge clk); reset = 0;
        repeat (2) @(posedge clk);

        // ── TC1: all-zeros masks → 0 events ──────────────────────────────────
        $display("--- TC1: all-zeros (no events) ---");
        write_a(0, 32'h0, 0); write_a(1, 32'h0, 0);
        write_a(2, 32'h0, 0); write_a(3, 32'h0, 0);
        write_b(0, 32'h0, 0); write_b(1, 32'h0, 0);
        write_b(2, 32'h0, 0); write_b(3, 32'h0, 0);

        run_and_wait;

        check_int("TC1 match_count", match_count, 0);
        check_bit("TC1 overflow=0",  overflow,    1'b0);
        check_int("TC1 lane_valid=0", |lane_valid, 0);

        // ── TC2: single event (row=0, col=0, k=0) → lane 0 ──────────────────
        // a[0] mask = 32'h1 (k=0 only), b[0] mask = 32'h1 (k=0 only)
        // col_cnt[c>0]=0 → col_acc all = 1 ≤ 128 → active_b_cols=4, match_count=1
        $display("--- TC2: single event (r=0,c=0,k=0) ---");
        write_a(0, 32'h1, 0); write_a(1, 32'h0, 0);
        write_a(2, 32'h0, 0); write_a(3, 32'h0, 0);
        write_b(0, 32'h1, 0); write_b(1, 32'h0, 0);
        write_b(2, 32'h0, 0); write_b(3, 32'h0, 0);

        run_and_wait;

        check_int("TC2 match_count",   match_count,   1);
        check_int("TC2 active_b_cols", active_b_cols, 4);
        check_bit("TC2 overflow=0",    overflow,      1'b0);
        check_lane(0, 0, 0, 0);
        // lanes 1..127 should be invalid
        begin
            integer bad;
            bad = 0;
            for (i = 1; i < LANES; i = i + 1)
                if (lane_valid[i]) bad = bad + 1;
            check_int("TC2 lanes 1..127 invalid", bad, 0);
        end

        // ── TC3: dense B col 0, all A rows full → 128 events, all lanes ──────
        // A[r] = 32'hFFFFFFFF for r=0..3; B[0] = 32'hFFFFFFFF, B[1..3] = 0
        // col_cnt[0]=128, col_cnt[1..3]=0
        // col_acc[c] = 128 for all c → all ≤ 128 → active_b_cols=4, match_count=128
        //
        // Lane pattern (verified by golden model):
        //   lane l → row=l/32, col=0, k=l%32
        $display("--- TC3: dense B col 0, all A rows full (128 events) ---");
        write_a(0, 32'hFFFFFFFF, 0); write_a(1, 32'hFFFFFFFF, 0);
        write_a(2, 32'hFFFFFFFF, 0); write_a(3, 32'hFFFFFFFF, 0);
        write_b(0, 32'hFFFFFFFF, 0); write_b(1, 32'h0, 0);
        write_b(2, 32'h0, 0);        write_b(3, 32'h0, 0);

        run_and_wait;

        check_int("TC3 match_count",   match_count,   128);
        check_int("TC3 active_b_cols", active_b_cols, 4);
        check_bit("TC3 overflow=0",    overflow,      1'b0);
        check_int("TC3 all lanes valid", &lane_valid, 1);

        // Spot-check boundary lanes
        check_lane(0,   0, 0, 0);   // lane 0: row=0/32=0, k=0%32=0
        check_lane(31,  0, 0, 31);  // lane 31: row=0, k=31
        check_lane(32,  1, 0, 0);   // lane 32: row=32/32=1, k=0
        check_lane(63,  1, 0, 31);  // lane 63: row=1, k=31
        check_lane(64,  2, 0, 0);   // lane 64: row=2, k=0
        check_lane(95,  2, 0, 31);
        check_lane(96,  3, 0, 0);   // lane 96: row=3, k=0
        check_lane(127, 3, 0, 31);  // lane 127: row=3, k=31

        // Full sweep: lane l → (row=l/32, col=0, k=l%32)
        begin : tc3_full
            integer l, errs;
            errs = 0;
            for (l = 0; l < LANES; l = l + 1) begin
                if (lane_valid[l] !== 1'b1 ||
                    get_row(l) !== l/32 ||
                    get_col(l) !== 0    ||
                    get_k(l)   !== l%32)
                    errs = errs + 1;
            end
            check_int("TC3 full lane sweep errors", errs, 0);
        end

        // ── TC4: two sparse B cols (k=0..7), all A rows → 64 events ─────────
        // A[r] = 32'hFFFFFFFF; B[0]=32'hFF, B[1]=32'hFF, B[2..3]=0
        // col_cnt[0]=4*8=32, col_cnt[1]=32, col_cnt[2..3]=0
        // col_acc[0]=32, col_acc[1]=64, col_acc[2..3]=64 → all ≤ 128
        // active_b_cols=4, match_count=64, overflow=0
        //
        // Lane pattern (verified by golden model):
        //   lane l (0≤l<64): row=l/16, col=(l/8)%2, k=l%8
        //   lanes 64..127: invalid
        $display("--- TC4: two sparse B cols k=0..7 (64 events) ---");
        write_a(0, 32'hFFFFFFFF, 0); write_a(1, 32'hFFFFFFFF, 0);
        write_a(2, 32'hFFFFFFFF, 0); write_a(3, 32'hFFFFFFFF, 0);
        write_b(0, 32'hFF, 0); write_b(1, 32'hFF, 0);
        write_b(2, 32'h0, 0); write_b(3, 32'h0, 0);

        run_and_wait;

        check_int("TC4 match_count",   match_count,   64);
        check_int("TC4 active_b_cols", active_b_cols, 4);
        check_bit("TC4 overflow=0",    overflow,      1'b0);

        // Spot-check key boundary lanes
        check_lane(0,  0, 0, 0);   // row=0/16=0, col=(0/8)%2=0, k=0%8=0
        check_lane(7,  0, 0, 7);   // row=0, col=0, k=7
        check_lane(8,  0, 1, 0);   // row=0, col=(8/8)%2=1, k=0
        check_lane(15, 0, 1, 7);
        check_lane(16, 1, 0, 0);   // row=16/16=1, col=0, k=0
        check_lane(23, 1, 0, 7);
        check_lane(24, 1, 1, 0);
        check_lane(31, 1, 1, 7);
        check_lane(32, 2, 0, 0);
        check_lane(47, 2, 1, 7);
        check_lane(48, 3, 0, 0);
        check_lane(63, 3, 1, 7);

        // Full sweep lanes 0..63
        begin : tc4_full
            integer l, errs;
            errs = 0;
            for (l = 0; l < 64; l = l + 1) begin
                if (lane_valid[l] !== 1'b1      ||
                    get_row(l) !== l/16          ||
                    get_col(l) !== (l/8)%2       ||
                    get_k(l)   !== l%8)
                    errs = errs + 1;
            end
            check_int("TC4 lanes 0..63 full sweep errors", errs, 0);
        end

        // Lanes 64..127 must be invalid
        begin : tc4_invalid
            integer l, errs;
            errs = 0;
            for (l = 64; l < LANES; l = l + 1)
                if (lane_valid[l]) errs = errs + 1;
            check_int("TC4 lanes 64..127 all invalid", errs, 0);
        end

        // ── TC5: consecutive run — same inputs as TC4, verify pipeline clears ─
        $display("--- TC5: consecutive run (same as TC4) ---");
        // No buffer writes needed (data unchanged)
        run_and_wait;

        check_int("TC5 match_count",   match_count,   64);
        check_bit("TC5 overflow=0",    overflow,      1'b0);
        begin : tc5_full
            integer l, errs;
            errs = 0;
            for (l = 0; l < 64; l = l + 1) begin
                if (lane_valid[l] !== 1'b1      ||
                    get_row(l) !== l/16          ||
                    get_col(l) !== (l/8)%2       ||
                    get_k(l)   !== l%8)
                    errs = errs + 1;
            end
            check_int("TC5 lanes 0..63 correct", errs, 0);
        end

        // ── Summary ───────────────────────────────────────────────────────────
        $display("------------------------------------------");
        $display("Result: %0d passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL PASS");
        else                $display("SOME FAILURES");
        $display("------------------------------------------");
        $finish;
    end

endmodule
