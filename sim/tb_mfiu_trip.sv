// =============================================================================
// tb_mfiu_trip.sv — TrIP 交集轉換層單元測試
// =============================================================================
// 測 module: rtl/mfiu/mfiu_trip.sv(+ rtl/mfiu/mfiu.v 核心)
// 跑法: make tb_mfiu_trip
//
// 範例(手算):NR=NC=4, KB=4, LANES=4
//   A: fiber0={k0,k1}, fiber1={k2}   → a_bitmask = 16'b...0100_0011
//   B: col0={k0},      col1={k1,k2}   → b_bitmask = 16'b...0110_0001
//   掃描序 (r,c,k) 命中:
//     L0=(r0,c0,k0)  L1=(r0,c1,k1)  L2=(r1,c1,k2)   count=3
//   座標: a_row={0,0,1} b_col={0,1,1} k={0,1,2}
//   輸出 C:(0,0)(0,1)(1,1) 全不同 → cut_after = ..011
// =============================================================================
`timescale 1ns/1ps

module tb_mfiu_trip;
    import trapezoid_pkg::*;

    localparam int LN = 4, RW = 2, CW = 2, KW = 2;

    logic [N_MUL_ROW-1:0] a_bm, b_bm;
    logic [LN-1:0]        lvalid;
    logic [LN*RW-1:0]     rowsel;
    logic [LN*CW-1:0]     colsel;
    logic [LN*KW-1:0]     ksel;
    logic [2:0]           cnt;
    logic                 ovf;
    logic [N_MUL_ROW-2:0] cut;
    int fails = 0;

    mfiu_trip dut (
        .a_bitmask(a_bm), .b_bitmask(b_bm),
        .lane_valid(lvalid), .a_row_sel(rowsel), .b_col_sel(colsel),
        .k_sel(ksel), .match_count(cnt), .overflow(ovf), .cut_after(cut)
    );

    task automatic chk(input string m, input int got, input int exp);
        if (got !== exp) begin
            $display("[FAIL] %s: got %0d, exp %0d", m, got, exp); fails++;
        end else
            $display("[PASS] %s = %0d", m, got);
    endtask

    initial begin
        // ── T1:稀疏 3 命中,3 個不同輸出 ──
        a_bm = 16'b0000_0000_0100_0011;
        b_bm = 16'b0000_0000_0110_0001;
        #1;
        chk("T1 count", cnt, 3);
        chk("T1 overflow", ovf, 0);
        chk("T1 row[0]", rowsel[0*RW +: RW], 0); chk("T1 row[1]", rowsel[1*RW +: RW], 0); chk("T1 row[2]", rowsel[2*RW +: RW], 1);
        chk("T1 col[0]", colsel[0*CW +: CW], 0); chk("T1 col[1]", colsel[1*CW +: CW], 1); chk("T1 col[2]", colsel[2*CW +: CW], 1);
        chk("T1 k[0]",   ksel[0*KW +: KW], 0);   chk("T1 k[1]",   ksel[1*KW +: KW], 1);   chk("T1 k[2]",   ksel[2*KW +: KW], 2);
        chk("T1 cut[0]", cut[0], 1); chk("T1 cut[1]", cut[1], 1); chk("T1 cut[2]", cut[2], 0);

        // ── T2:同一輸出 C 的多個 k(連續、不剪)──
        //   A: f0={k0,k1,k2}; B: c0={k0,k1,k2}  → 3 命中全屬 (r0,c0)
        a_bm = 16'b0000_0000_0000_0111;
        b_bm = 16'b0000_0000_0000_0111;
        #1;
        chk("T2 count", cnt, 3);
        chk("T2 row[2]", rowsel[2*RW +: RW], 0); chk("T2 col[2]", colsel[2*CW +: CW], 0);
        chk("T2 k[0]", ksel[0*KW +: KW], 0); chk("T2 k[1]", ksel[1*KW +: KW], 1); chk("T2 k[2]", ksel[2*KW +: KW], 2);
        chk("T2 cut[0]", cut[0], 0); chk("T2 cut[1]", cut[1], 0);   // 同段不剪

        // ── T3:全滿 → 命中 > LANES → overflow ──
        a_bm = 16'hFFFF; b_bm = 16'hFFFF;
        #1;
        chk("T3 overflow", ovf, 1);

        // ── T4:無命中 ──
        a_bm = 16'h0001; b_bm = 16'h0002;
        #1;
        chk("T4 count", cnt, 0);
        chk("T4 overflow", ovf, 0);

        $display("");
        if (fails == 0) begin
            $display("==============================");
            $display("ALL TESTS PASSED");
            $display("==============================");
        end else begin
            $display("==============================");
            $display("%0d TEST(S) FAILED", fails);
            $display("==============================");
        end
        $finish;
    end
endmodule
