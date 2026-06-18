`timescale 1ns/1ps

// Testbench for mfiu.v
// Golden cases are taken directly from HARDWARE_STRUCTURE.md §29.

module tb_mfiu;

    // ── Parameters (match DUT defaults) ─────────────────────────────────────
    localparam NUM_ROWS  = 2;
    localparam NUM_COLS  = 2;
    localparam K_BITS    = 4;
    localparam LANES     = 16;
    localparam ROW_IDX_W = 1;   // clog2(2)
    localparam COL_IDX_W = 1;
    localparam K_IDX_W   = 2;   // clog2(4)
    localparam ACTIVE_COLS_W = 2; // clog2(2+1)
    localparam CNT_W     = 5;   // clog2(17)

    localparam P_NUM_ROWS = 4;
    localparam P_NUM_COLS = 4;
    localparam P_K_BITS   = 32;
    localparam P_LANES    = 128;
    localparam P_ROW_IDX_W = 2;
    localparam P_COL_IDX_W = 2;
    localparam P_K_IDX_W   = 5;
    localparam P_ACTIVE_COLS_W = 3;
    localparam P_CNT_W = 8;

    // ── DUT ports ────────────────────────────────────────────────────────────
    reg  [NUM_ROWS*K_BITS-1:0]  a_mask_i;
    reg  [NUM_COLS*K_BITS-1:0]  b_mask_i;

    wire [LANES-1:0]             lane_valid_o;
    wire [LANES*ROW_IDX_W-1:0]  a_row_sel_o;
    wire [LANES*COL_IDX_W-1:0]  b_col_sel_o;
    wire [LANES*K_IDX_W-1:0]    k_sel_o;
    wire [CNT_W-1:0]             match_count_o;
    wire [ACTIVE_COLS_W-1:0]     active_b_cols_o;
    wire                         overflow_o;

    reg  [P_NUM_ROWS*P_K_BITS-1:0] p_a_mask_i;
    reg  [P_NUM_COLS*P_K_BITS-1:0] p_b_mask_i;
    wire [P_LANES-1:0]             p_lane_valid_o;
    wire [P_LANES*P_ROW_IDX_W-1:0] p_a_row_sel_o;
    wire [P_LANES*P_COL_IDX_W-1:0] p_b_col_sel_o;
    wire [P_LANES*P_K_IDX_W-1:0]   p_k_sel_o;
    wire [P_CNT_W-1:0]             p_match_count_o;
    wire [P_ACTIVE_COLS_W-1:0]     p_active_b_cols_o;
    wire                           p_overflow_o;

    mfiu #(
        .NUM_ROWS  (NUM_ROWS),
        .NUM_COLS  (NUM_COLS),
        .K_BITS    (K_BITS),
        .LANES     (LANES),
        .PACKED_MODE (1)
    ) dut (
        .a_mask_i     (a_mask_i),
        .b_mask_i     (b_mask_i),
        .lane_valid_o (lane_valid_o),
        .a_row_sel_o  (a_row_sel_o),
        .b_col_sel_o  (b_col_sel_o),
        .k_sel_o      (k_sel_o),
        .match_count_o(match_count_o),
        .active_b_cols_o(active_b_cols_o),
        .overflow_o   (overflow_o)
    );

    mfiu #(
        .NUM_ROWS    (P_NUM_ROWS),
        .NUM_COLS    (P_NUM_COLS),
        .K_BITS      (P_K_BITS),
        .LANES       (P_LANES),
        .PACKED_MODE (1)
    ) paper_dut (
        .a_mask_i        (p_a_mask_i),
        .b_mask_i        (p_b_mask_i),
        .lane_valid_o    (p_lane_valid_o),
        .a_row_sel_o     (p_a_row_sel_o),
        .b_col_sel_o     (p_b_col_sel_o),
        .k_sel_o         (p_k_sel_o),
        .match_count_o   (p_match_count_o),
        .active_b_cols_o (p_active_b_cols_o),
        .overflow_o      (p_overflow_o)
    );

    // ── Helpers ──────────────────────────────────────────────────────────────
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // Extract one field from a packed lane array
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

    function [P_ROW_IDX_W-1:0] p_get_row;
        input [P_LANES*P_ROW_IDX_W-1:0] arr;
        input integer lane;
        p_get_row = arr[lane*P_ROW_IDX_W +: P_ROW_IDX_W];
    endfunction

    function [P_COL_IDX_W-1:0] p_get_col;
        input [P_LANES*P_COL_IDX_W-1:0] arr;
        input integer lane;
        p_get_col = arr[lane*P_COL_IDX_W +: P_COL_IDX_W];
    endfunction

    function [P_K_IDX_W-1:0] p_get_k;
        input [P_LANES*P_K_IDX_W-1:0] arr;
        input integer lane;
        p_get_k = arr[lane*P_K_IDX_W +: P_K_IDX_W];
    endfunction

    task check;
        input [159:0] label;
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
        input [159:0] label;
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

    // Apply inputs and wait one combinational settling time
    task apply;
        input [NUM_ROWS*K_BITS-1:0] am;
        input [NUM_COLS*K_BITS-1:0] bm;
        begin
            a_mask_i = am;
            b_mask_i = bm;
            #1;   // combinational settle
        end
    endtask

    task apply_paper;
        input [P_NUM_ROWS*P_K_BITS-1:0] am;
        input [P_NUM_COLS*P_K_BITS-1:0] bm;
        begin
            p_a_mask_i = am;
            p_b_mask_i = bm;
            #1;
        end
    endtask

    // ── Test cases ───────────────────────────────────────────────────────────
    initial begin

        // =====================================================================
        // TC1: all zeros → no effectual MACs
        // =====================================================================
        apply(8'h00, 8'h00);
        p_a_mask_i = {P_NUM_ROWS*P_K_BITS{1'b0}};
        p_b_mask_i = {P_NUM_COLS*P_K_BITS{1'b0}};
        check_int("TC1 lane_valid=0     ", lane_valid_o,   16'h0000);
        check_int("TC1 match_count=0    ", match_count_o,  0);
        check_int("TC1 active_cols=2    ", active_b_cols_o, 2);
        check    ("TC1 overflow=0       ", overflow_o,     1'b0);

        // =====================================================================
        // TC2: single intersection at one (row,col,k)
        //   A0=4'b0001, A1=4'b0000, B0=4'b0001, B1=4'b0000
        //   Only A0[k0] & B0[k0] = 1 → 1 effectual MAC → lane0
        // =====================================================================
        apply({4'b0000, 4'b0001},   // a_mask: r1=4'b0000, r0=4'b0001
              {4'b0000, 4'b0001});  // b_mask: c1=4'b0000, c0=4'b0001
        check    ("TC2 lane0 valid       ", lane_valid_o[0], 1'b1);
        check_int("TC2 lane0 row=0      ", get_row(a_row_sel_o, 0), 0);
        check_int("TC2 lane0 col=0      ", get_col(b_col_sel_o, 0), 0);
        check_int("TC2 lane0 k=0        ", get_k  (k_sel_o,     0), 0);
        check    ("TC2 lane1 not valid  ", lane_valid_o[1], 1'b0);
        check_int("TC2 match_count=1   ", match_count_o,  1);
        check_int("TC2 active_cols=2   ", active_b_cols_o, 2);
        check    ("TC2 overflow=0       ", overflow_o,     1'b0);

        // =====================================================================
        // TC3: §29 worked example — 4 effectual MACs, no overflow
        //   A0=4'b1010, A1=4'b0110, B0=4'b1001, B1=4'b1010
        //
        //   pair(0,0): A0 & B0 = 1010 & 1001 = 1000 → k3
        //   pair(0,1): A0 & B1 = 1010 & 1010 = 1010 → k1, k3
        //   pair(1,0): A1 & B0 = 0110 & 1001 = 0000 → none
        //   pair(1,1): A1 & B1 = 0110 & 1010 = 0010 → k1
        //   Scan order (r,c,k low→high):
        // Packed mapping:
        //     lane0 ← (0,0,k3)
        //     lane1 ← (0,1,k1)
        //     lane2 ← (0,1,k3)
        //     lane3 ← (1,1,k1)
        // =====================================================================
        apply({4'b0110, 4'b1010},   // a_mask: r1=4'b0110, r0=4'b1010
              {4'b1010, 4'b1001});  // b_mask: c1=4'b1010, c0=4'b1001

        check_int("TC3 valid bitmap     ", lane_valid_o,   16'h000f);
        check_int("TC3 match_count=4    ", match_count_o,  4);
        check_int("TC3 active_cols=2    ", active_b_cols_o, 2);
        check    ("TC3 overflow=0        ", overflow_o,     1'b0);

        check_int("TC3 lane0 row=0      ", get_row(a_row_sel_o, 0), 0);
        check_int("TC3 lane0 col=0      ", get_col(b_col_sel_o, 0), 0);
        check_int("TC3 lane0 k=3        ", get_k  (k_sel_o,     0), 3);
        check_int("TC3 lane1 row=0      ", get_row(a_row_sel_o, 1), 0);
        check_int("TC3 lane1 col=1      ", get_col(b_col_sel_o, 1), 1);
        check_int("TC3 lane1 k=1        ", get_k  (k_sel_o,     1), 1);
        check_int("TC3 lane2 row=0      ", get_row(a_row_sel_o, 2), 0);
        check_int("TC3 lane2 col=1      ", get_col(b_col_sel_o, 2), 1);
        check_int("TC3 lane2 k=3        ", get_k  (k_sel_o,     2), 3);
        check_int("TC3 lane3 row=1      ", get_row(a_row_sel_o, 3), 1);
        check_int("TC3 lane3 col=1      ", get_col(b_col_sel_o, 3), 1);
        check_int("TC3 lane3 k=1        ", get_k  (k_sel_o,     3), 1);

        // =====================================================================
        // TC4: both A fibers all-ones, B0 all-ones → 8 direct-mapped hits
        //   A0=4'b1111, A1=4'b1111, B0=4'b1111, B1=4'b0000
        //   pair(0,0): 4 hits, pair(0,1): 0, pair(1,0): 4 hits, pair(1,1): 0
        //   total=8, LANES=16 → no overflow
        // =====================================================================
        apply({4'b1111, 4'b1111},   // both A fibers all-1
              {4'b0000, 4'b1111});  // B0 all-1, B1 all-0

        check_int("TC4 match_count=8        ", match_count_o, 8);
        check    ("TC4 overflow=0            ", overflow_o,    1'b0);
        check_int("TC4 valid bitmap          ", lane_valid_o, 16'h00ff);

        // =====================================================================
        // TC5: one A fiber all-zero, one B fiber all-zero → no match
        // =====================================================================
        apply({4'b1111, 4'b0000},   // A0=0000, A1=1111
              {4'b0000, 4'b1111});  // B0=1111, B1=0000
        // pair(0,0): 0000&1111=0000, pair(0,1): 0000&0000=0000
        // pair(1,0): 1111&1111=1111 → 4 hits, pair(1,1): 1111&0000=0000
        check_int("TC5 match_count=4        ", match_count_o, 4);
        check    ("TC5 overflow=0            ", overflow_o,    1'b0);
        // all hits belong to (r=1, c=0)
        check_int("TC5 valid bitmap          ", lane_valid_o, 16'h000f);
        check_int("TC5 lane0 row=1          ", get_row(a_row_sel_o, 0), 1);
        check_int("TC5 lane0 col=0          ", get_col(b_col_sel_o, 0), 0);

        // =====================================================================
        // TC6: single k-bit shared across all pairs → 4 hits (one per pair)
        //   A0=4'b1000, A1=4'b1000, B0=4'b1000, B1=4'b1000
        //   All pairs intersect only at k=3
        // =====================================================================
        apply({4'b1000, 4'b1000},
              {4'b1000, 4'b1000});
        check_int("TC6 match_count=4        ", match_count_o, 4);
        check    ("TC6 overflow=0            ", overflow_o,    1'b0);
        check_int("TC6 valid bitmap          ", lane_valid_o, 16'h000f);
        check_int("TC6 lane0 k=3            ", get_k(k_sel_o, 0), 3);
        check_int("TC6 lane1 k=3            ", get_k(k_sel_o, 1), 3);
        check_int("TC6 lane2 k=3            ", get_k(k_sel_o, 2), 3);
        check_int("TC6 lane3 k=3            ", get_k(k_sel_o, 3), 3);

        // =====================================================================
        // TC7: paper-aligned 4 A rows x 4 B columns, 128-lane capacity.
        // Dense inputs would create 4*4*32 = 512 effectual MACs, so the dynamic
        // B-column policy must select only one B column: 4*1*32 = 128.
        // =====================================================================
        apply_paper({P_NUM_ROWS*P_K_BITS{1'b1}},
                    {P_NUM_COLS*P_K_BITS{1'b1}});
        check_int("TC7 paper active_cols=1 ", p_active_b_cols_o, 1);
        check_int("TC7 paper match_count=128", p_match_count_o, 128);
        check    ("TC7 paper overflow=0     ", p_overflow_o, 1'b0);
        check    ("TC7 paper all lanes valid", &p_lane_valid_o, 1'b1);
        check_int("TC7 paper lane0 row      ", p_get_row(p_a_row_sel_o, 0), 0);
        check_int("TC7 paper lane0 col      ", p_get_col(p_b_col_sel_o, 0), 0);
        check_int("TC7 paper lane0 k        ", p_get_k(p_k_sel_o, 0), 0);
        check_int("TC7 paper lane127 row    ", p_get_row(p_a_row_sel_o, 127), 3);
        check_int("TC7 paper lane127 col    ", p_get_col(p_b_col_sel_o, 127), 0);
        check_int("TC7 paper lane127 k      ", p_get_k(p_k_sel_o, 127), 31);

        // =====================================================================
        // TC8: all four B columns fit when each column has only one active k.
        // Total effectual MACs = 4 rows * 4 cols * 1 k = 16.
        // =====================================================================
        apply_paper({P_NUM_ROWS*P_K_BITS{1'b1}},
                    {P_NUM_COLS{32'h0000_0001}});
        check_int("TC8 paper active_cols=4 ", p_active_b_cols_o, 4);
        check_int("TC8 paper match_count=16", p_match_count_o, 16);
        check    ("TC8 paper overflow=0     ", p_overflow_o, 1'b0);
        check_int("TC8 paper valid bitmap   ", p_lane_valid_o[15:0], 16'hffff);
        check_int("TC8 paper lane15 row     ", p_get_row(p_a_row_sel_o, 15), 3);
        check_int("TC8 paper lane15 col     ", p_get_col(p_b_col_sel_o, 15), 3);
        check_int("TC8 paper lane15 k       ", p_get_k(p_k_sel_o, 15), 0);

        // ── Summary ──────────────────────────────────────────────────────────
        $display("------------------------------------------");
        $display("Result: %0d passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("ALL PASS");
        else
            $display("SOME FAILURES");
        $display("------------------------------------------");
        $finish;
    end

endmodule
