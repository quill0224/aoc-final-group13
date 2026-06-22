// =============================================================================
// tb_pe_mfiu_seq.sv — verify pe_mfiu_seq + REAL mfiu (dynamic 1-4 grouping + meta)
// Build/run: --binary --timing -Irtl, top = tb_pe_mfiu_seq (full command in handoff notes).
// =============================================================================
`timescale 1ns/1ps

module tb_pe_mfiu_seq;
  import trapezoid_pkg::*;

  logic clk = 0, rst, mode, start, done;
  logic [N_MUL_ROW-1:0] a_bm_row;
  logic [N_MUL_ROW-1:0] b_bm [0:15];
  logic                      out_valid;
  logic [LANE_COUNT_W-1:0]   out_eff;
  logic [N_MUL_ROW-1:0][3:0] out_a_meta;
  logic [N_MUL_ROW-1:0][5:0] out_b_meta;
  logic [3:0]                out_grp_base;
  logic [2:0]                out_grp_ncol;

  always #5 clk = ~clk;

  pe_mfiu_seq dut (
    .clk(clk), .rst_n(~rst), .mode(mode), .start(start), .done(done),
    .a_bm_row(a_bm_row), .b_bm(b_bm),
    .out_valid(out_valid), .out_effectual(out_eff),
    .out_a_meta(out_a_meta), .out_b_meta(out_b_meta),
    .out_grp_base(out_grp_base), .out_grp_ncol(out_grp_ncol)
  );

  // ── capture per group ──
  integer g_cnt, fails, i;
  logic [3:0] base_arr [0:31];
  logic [2:0] ncol_arr [0:31];
  logic [4:0] eff_arr  [0:31];
  logic [3:0] g0_a [0:3];   // group0 的前 4 lane(驗真 meta)
  logic [5:0] g0_b [0:3];

  always_ff @(posedge clk) begin
    if (start) g_cnt <= 0;
    else if (out_valid) begin
      base_arr[g_cnt] <= out_grp_base;
      ncol_arr[g_cnt] <= out_grp_ncol;
      eff_arr[g_cnt]  <= out_eff;
      if (g_cnt == 0) begin
        g0_a[0] <= out_a_meta[0]; g0_a[1] <= out_a_meta[1];
        g0_a[2] <= out_a_meta[2]; g0_a[3] <= out_a_meta[3];
        g0_b[0] <= out_b_meta[0]; g0_b[1] <= out_b_meta[1];
        g0_b[2] <= out_b_meta[2]; g0_b[3] <= out_b_meta[3];
      end
      g_cnt <= g_cnt + 1;
    end
  end

  initial begin
    fails = 0; g_cnt = 0; rst = 1; mode = 1; start = 0; a_bm_row = 0;
    for (i = 0; i < 16; i = i + 1) b_bm[i] = 0;
    repeat (3) @(posedge clk); @(negedge clk); rst = 0;

    // ===== Test 1: sparse → 塞滿 4 欄/group;group0 比對真 meta =====
    a_bm_row = 16'h0029;                 // bits 0,3,5
    for (i = 0; i < 16; i = i + 1) b_bm[i] = 0;
    b_bm[0] = 16'h0021;                  // bits 0,5
    b_bm[1] = 16'h0028;                  // bits 3,5
    @(negedge clk); start = 1; @(negedge clk); start = 0;
    @(posedge done); repeat (2) @(posedge clk); #0.1;

    $display("--- Test1 (sparse): groups=%0d ---", g_cnt);
    if (g_cnt !== 4) begin $display("[FAIL] T1 groups=%0d exp 4", g_cnt); fails++; end
    for (i = 0; i < 4; i = i + 1)
      if (base_arr[i] !== i*4 || ncol_arr[i] !== 4)
        begin $display("[FAIL] T1 grp%0d base=%0d ncol=%0d (exp base=%0d ncol=4)", i, base_arr[i], ncol_arr[i], i*4); fails++; end
    if (eff_arr[0] !== 5'd4) begin $display("[FAIL] T1 grp0 eff=%0d exp 4", eff_arr[0]); fails++; end
    if (eff_arr[1] !== 0 || eff_arr[2] !== 0 || eff_arr[3] !== 0)
      begin $display("[FAIL] T1 grp1-3 eff = %0d %0d %0d exp 0", eff_arr[1], eff_arr[2], eff_arr[3]); fails++; end
    // group0 真 meta(= tb_mfiu basic 的 known-answer)
    if (g0_a[0]!==4'd0 || g0_b[0]!==6'h00 || g0_a[1]!==4'd2 || g0_b[1]!==6'h01 ||
        g0_a[2]!==4'd1 || g0_b[2]!==6'h10 || g0_a[3]!==4'd2 || g0_b[3]!==6'h11) begin
      $display("[FAIL] T1 grp0 meta: a=%0d,%0d,%0d,%0d b=%h,%h,%h,%h (exp a=0,2,1,2 b=00,01,10,11)",
               g0_a[0],g0_a[1],g0_a[2],g0_a[3], g0_b[0],g0_b[1],g0_b[2],g0_b[3]); fails++;
    end else $display("[PASS] T1: 4 groups x ncol4; grp0 eff=4 + real meta a={0,2,1,2} b={00,01,10,11}");

    // ===== Test 2: dense → 每欄 eff=16 → 每 group 1 欄 =====
    a_bm_row = 16'hFFFF;
    for (i = 0; i < 16; i = i + 1) b_bm[i] = 16'hFFFF;
    @(negedge clk); start = 1; @(negedge clk); start = 0;
    @(posedge done); repeat (2) @(posedge clk); #0.1;

    $display("--- Test2 (dense): groups=%0d ---", g_cnt);
    if (g_cnt !== 16) begin $display("[FAIL] T2 groups=%0d exp 16", g_cnt); fails++; end
    for (i = 0; i < 16; i = i + 1)
      if (base_arr[i] !== i || ncol_arr[i] !== 1 || eff_arr[i] !== 5'd16)
        begin $display("[FAIL] T2 grp%0d base=%0d ncol=%0d eff=%0d (exp base=%0d ncol1 eff16)", i, base_arr[i], ncol_arr[i], eff_arr[i], i); fails++; end
    // group0 (col0): a=b=0xFFFF → lane l: a_meta=l, b_meta={0,l}
    if (g0_a[0]!==4'd0 || g0_b[0]!==6'h00 || g0_a[1]!==4'd1 || g0_b[1]!==6'h01 ||
        g0_a[2]!==4'd2 || g0_b[2]!==6'h02 || g0_a[3]!==4'd3 || g0_b[3]!==6'h03)
      begin $display("[FAIL] T2 grp0 meta a=%0d,%0d,%0d,%0d b=%h,%h,%h,%h (exp a=0,1,2,3 b=00,01,02,03)",
                     g0_a[0],g0_a[1],g0_a[2],g0_a[3],g0_b[0],g0_b[1],g0_b[2],g0_b[3]); fails++; end
    else $display("[PASS] T2: 16 groups x ncol1 x eff16; grp0 meta a={0,1,2,3} b={00..03}");

    $display("");
    if (fails == 0) $display("==== TB PASS ===="); else $display("==== TB FAIL (%0d) ====", fails);
    $finish;
  end

  initial begin #500000; $display("[ERR] timeout"); $finish; end
endmodule
