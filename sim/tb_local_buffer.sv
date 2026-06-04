// =============================================================================
// tb_local_buffer.sv — local_buffer_row 單元測試
// =============================================================================
// 測 module: rtl/pe/local_buffer_row.sv
// Owner: 黃妍心
//
// 跑法: make tb_lbuf
// 看波形: gtkwave tb_local_buffer.vcd
//
// === 測什麼 ===
//   T1: reset 後 buffer 全 0(dump 任意 addr → 0)
//   T2: Dense IP 累加 — 單一 sub-tree(pos 15)→ addr 5,連加 4 次 ×3 = 12
//   T3: clear — 清零後 addr 5 變回 0
//   T4: TrIP scatter — 1 cycle 3 個 valid sub-tree 寫到不同 addr,各自正確
//   T5: K-tile 累加 — 同 addr 跨 cycle 累加不同值(100+50=150)
//   T6: 多 addr 獨立性 — 不同 addr 互不干擾
// =============================================================================

`timescale 1ns/1ps

module tb_local_buffer;
    import trapezoid_pkg::*;

    logic                                         clk = 0;
    logic                                         rst_n;
    logic                                         en;
    logic signed [N_MUL_ROW-1:0][ACC_W-1:0]       subtree_sums;
    logic        [N_MUL_ROW-1:0]                  subtree_valid;
    logic        [N_MUL_ROW-1:0][LOCAL_BUF_AW-1:0] out_addr;
    logic                                         clear;
    logic                                         acc_en;
    logic                                         dump_en;
    logic        [LOCAL_BUF_AW-1:0]               dump_addr;
    logic                                         c_valid;
    logic signed [ACC_W-1:0]                      c_out;

    int fails;
    integer i;

    always #1 clk = ~clk;

    local_buffer_row dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .en            (en),
        .subtree_sums  (subtree_sums),
        .subtree_valid (subtree_valid),
        .out_addr      (out_addr),
        .clear         (clear),
        .acc_en        (acc_en),
        .dump_en       (dump_en),
        .dump_addr     (dump_addr),
        .c_valid       (c_valid),
        .c_out         (c_out)
    );

    // ── helpers ──────────────────────────────────────────────
    // 清空所有 sub-tree 輸入
    task clear_in;
        for (i = 0; i < N_MUL_ROW; i = i + 1) begin
            subtree_valid[i] = 1'b0;
            subtree_sums[i]  = '0;
            out_addr[i]      = '0;
        end
    endtask

    // 設一個 valid sub-tree:position p → addr a,值 v
    task set_st(input integer p,
                input [LOCAL_BUF_AW-1:0] a,
                input signed [ACC_W-1:0] v);
        subtree_valid[p] = 1'b1;
        out_addr[p]      = a;
        subtree_sums[p]  = v;
    endtask

    // 累加 k 個 cycle(inputs 已設好)
    task do_acc(input integer k);
        integer n;
        @(negedge clk); acc_en = 1; dump_en = 0; clear = 0;
        for (n = 0; n < k; n = n + 1) @(posedge clk);
        @(negedge clk); acc_en = 0;
        #0.1;
    endtask

    // 清零整個 buffer
    task do_clear;
        @(negedge clk); clear = 1; acc_en = 0; dump_en = 0;
        @(posedge clk); #0.1;
        @(negedge clk); clear = 0;
    endtask

    // 讀某 addr,比對期望值
    task check_dump(input [LOCAL_BUF_AW-1:0] a,
                    input signed [ACC_W-1:0] exp,
                    input string msg);
        @(negedge clk); dump_en = 1; dump_addr = a; acc_en = 0; clear = 0;
        @(posedge clk); #0.1;
        if (c_valid !== 1'b1) begin
            $display("[FAIL] %s: c_valid=%b (expected 1)", msg, c_valid);
            fails = fails + 1;
        end else if (c_out !== exp) begin
            $display("[FAIL] %s: addr=%0d c_out=%0d (expected %0d)", msg, a, c_out, exp);
            fails = fails + 1;
        end else begin
            $display("[PASS] %s: addr=%0d c_out=%0d", msg, a, c_out);
        end
        @(negedge clk); dump_en = 0;
    endtask

    // ── 主流程 ────────────────────────────────────────────────
    initial begin
        $dumpfile("tb_local_buffer.vcd");
        $dumpvars(0, tb_local_buffer);
        fails = 0;

        rst_n = 0; en = 0;
        clear = 0; acc_en = 0; dump_en = 0; dump_addr = 0;
        clear_in;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1; en = 1;

        // T1: reset 後全 0
        check_dump(9'd5, 32'sd0, "T1 reset addr5=0");

        // T2: Dense IP 累加 — pos 15 → addr 5,連加 4 次,每次 +3 → 12
        clear_in;
        set_st(15, 9'd5, 32'sd3);
        do_acc(4);
        check_dump(9'd5, 32'sd12, "T2 dense accumulate 4x3=12");

        // T3: clear → addr 5 回 0
        do_clear;
        check_dump(9'd5, 32'sd0, "T3 after clear addr5=0");

        // T4: TrIP scatter — 1 cycle,3 個 sub-tree 寫不同 addr
        clear_in;
        set_st(0, 9'd1, 32'sd10);
        set_st(2, 9'd2, 32'sd20);
        set_st(3, 9'd3, 32'sd4);
        do_acc(1);
        check_dump(9'd1, 32'sd10, "T4 scatter addr1=10");
        check_dump(9'd2, 32'sd20, "T4 scatter addr2=20");
        check_dump(9'd3, 32'sd4,  "T4 scatter addr3=4");

        // T5: K-tile 累加 — 同 addr 7 跨 cycle 累加 100 + 50 = 150
        do_clear;
        clear_in;
        set_st(15, 9'd7, 32'sd100);
        do_acc(1);
        clear_in;
        set_st(15, 9'd7, 32'sd50);
        do_acc(1);
        check_dump(9'd7, 32'sd150, "T5 K-tile 100+50=150");

        // T6: 多 addr 獨立性(承 T5,addr 7=150;新寫 addr 8=77,addr7 不變)
        clear_in;
        set_st(15, 9'd8, 32'sd77);
        do_acc(1);
        check_dump(9'd8, 32'sd77,  "T6 addr8=77 (independent)");
        check_dump(9'd7, 32'sd150, "T6 addr7 still 150 (untouched)");

        // 結束
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
        #100000;
        $display("[ERR] timeout");
        $finish;
    end

endmodule
