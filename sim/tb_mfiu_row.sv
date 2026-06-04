// =============================================================================
// tb_mfiu_row.sv — mfiu_row 單元測試
// =============================================================================
// 測 module: rtl/mfiu/mfiu_row.sv
// 介面 owner: 黃妍心   ·   multi-fiber body owner: 楊承豫
//
// 測 intersection + prefix-sum 壓縮(延 MFIU_STAGES 拍後):
//   T1 reset
//   T2/T3 Dense(bitmask 全 1)→ idx=identity, count=16, out_addr[15]=cur_n
//   T4/T5 sparse → idx 壓縮到前面, count=effectual 數
// 期望值由 tb 從 (a_bitmask & b_bitmask) 自行算出,對拍 DUT。
// =============================================================================

`timescale 1ns/1ps

module tb_mfiu_row;
    import trapezoid_pkg::*;

    logic                                   clk = 0;
    logic                                   rst_n;
    logic                                   en;
    logic                                   in_valid;
    logic [1:0]                             dataflow_sel;
    logic [LOCAL_BUF_AW-1:0]                cur_n;
    logic [N_MUL_ROW-1:0]                   a_bitmask;
    logic [N_MUL_ROW-1:0]                   b_bitmask;
    logic [N_MUL_ROW-1:0][4:0]              effectual_idx;
    logic [4:0]                             effectual_count;
    logic [N_MUL_ROW-2:0]                   cut_after;
    logic [N_MUL_ROW-1:0][LOCAL_BUF_AW-1:0] out_addr;
    logic                                   meta_valid;

    int fails;
    integer i;

    always #1 clk = ~clk;

    mfiu_row dut (
        .clk(clk), .rst_n(rst_n), .en(en), .in_valid(in_valid),
        .dataflow_sel(dataflow_sel), .cur_n(cur_n),
        .a_bitmask(a_bitmask), .b_bitmask(b_bitmask),
        .effectual_idx(effectual_idx), .effectual_count(effectual_count),
        .cut_after(cut_after), .out_addr(out_addr), .meta_valid(meta_valid)
    );

    task wait_mfiu;
        repeat (MFIU_STAGES) @(posedge clk);
        #0.1;
    endtask

    // 從 (a_bitmask & b_bitmask) 算期望壓縮,對拍 DUT
    task check_meta(input [LOCAL_BUF_AW-1:0] exp_n, input string msg);
        logic [N_MUL_ROW-1:0] eff;
        logic [4:0]           exp_idx [N_MUL_ROW];
        integer kk, pp;
        logic ok;
        eff = a_bitmask & b_bitmask;
        for (kk = 0; kk < N_MUL_ROW; kk = kk + 1) exp_idx[kk] = 5'd0;
        pp = 0;
        for (kk = 0; kk < N_MUL_ROW; kk = kk + 1)
            if (eff[kk]) begin exp_idx[pp] = kk[4:0]; pp = pp + 1; end

        ok = 1'b1;
        if (effectual_count !== pp[4:0]) begin
            $display("[FAIL] %s: count=%0d (expected %0d)", msg, effectual_count, pp); ok = 0;
        end
        for (kk = 0; kk < pp; kk = kk + 1)
            if (effectual_idx[kk] !== exp_idx[kk]) begin
                $display("[FAIL] %s: idx[%0d]=%0d (expected %0d)", msg, kk, effectual_idx[kk], exp_idx[kk]); ok = 0;
            end
        if (cut_after !== '0) begin
            $display("[FAIL] %s: cut_after=%h (expected 0)", msg, cut_after); ok = 0;
        end
        if (out_addr[N_MUL_ROW-1] !== exp_n) begin
            $display("[FAIL] %s: out_addr[15]=%0d (expected %0d)", msg, out_addr[N_MUL_ROW-1], exp_n); ok = 0;
        end
        if (meta_valid !== 1'b1) begin
            $display("[FAIL] %s: meta_valid=%b", msg, meta_valid); ok = 0;
        end
        if (ok) $display("[PASS] %s: count=%0d idx compacted, out_addr[15]=%0d", msg, pp, exp_n);
        else    fails = fails + 1;
    endtask

    initial begin
        $dumpfile("tb_mfiu_row.vcd");
        $dumpvars(0, tb_mfiu_row);
        fails = 0;

        rst_n = 0; en = 0; in_valid = 0;
        dataflow_sel = MODE_DENSE_IP;
        cur_n = '0; a_bitmask = '0; b_bitmask = '0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1; en = 1;

        // T1: reset 後 meta_valid=0
        @(posedge clk); #0.1;
        if (meta_valid === 1'b0) $display("[PASS] T1 reset: meta_valid=0");
        else begin $display("[FAIL] T1 reset: meta_valid=%b", meta_valid); fails = fails + 1; end

        // T2: Dense(全 1)cur_n=5 → identity, count=16
        @(negedge clk);
        in_valid = 1; cur_n = 9'd5; a_bitmask = 16'hFFFF; b_bitmask = 16'hFFFF;
        wait_mfiu;
        check_meta(9'd5, "T2 Dense identity count=16");

        // T3: Dense cur_n=42
        @(negedge clk);
        in_valid = 1; cur_n = 9'd42; a_bitmask = 16'hFFFF; b_bitmask = 16'hFFFF;
        wait_mfiu;
        check_meta(9'd42, "T3 Dense cur_n=42");

        // T4: sparse — eff = FFFF & 000A = bits 1,3 → idx=[1,3], count=2
        @(negedge clk);
        in_valid = 1; cur_n = 9'd9; a_bitmask = 16'hFFFF; b_bitmask = 16'h000A;
        wait_mfiu;
        check_meta(9'd9, "T4 sparse bits{1,3} count=2");

        // T5: sparse — eff = 00F0 & 0050 = bits 4,6 → idx=[4,6], count=2
        @(negedge clk);
        in_valid = 1; cur_n = 9'd9; a_bitmask = 16'h00F0; b_bitmask = 16'h0050;
        wait_mfiu;
        check_meta(9'd9, "T5 sparse bits{4,6} count=2");

        @(negedge clk); in_valid = 0;
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

    initial begin
        #100000; $display("[ERR] timeout"); $finish;
    end

endmodule
