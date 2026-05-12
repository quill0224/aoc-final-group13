// =============================================================================
// tb_merge_tree.sv — radix-16 merge tree unit test
// =============================================================================
// 測 module: rtl/dist/merge_tree_radix16.v
// Owner: 黃妍心 + QuillQ
//
// 跑法: make tb_tree
// 看波形: gtkwave tb_merge_tree.vcd
//
// 測什麼 (抗架構變動原則:只測「16 個 INT16 加總 = 1 個 INT32」的基本功能):
//   T1: reset 後 sum = 0
//   T2: 全 1 → sum = 16
//   T3: 全 -1 → sum = -16
//   T4: 1..16 → sum = 136
//   T5: 邊界值 INT16_MAX × 16 → sum = 524272 (不溢位)
//   T6: 正負混合 → sum = 0
//
// 時序:
//   tree 是 4-stage pipelined,latency = 4 cycles
//   posedge clk N 時:
//     - s1 抓 N-1 的 partials
//     - s2 抓 N-1 的 s1
//     - ...
//     - sum 抓 N-1 的 s3
//   所以 partials 從 cycle 0 開始穩定,sum 在 cycle 4 才出結果
//
//   en=1 必須維持整段 pipeline 跑滿(我寫的版本是「所有 stage 同步 en」),
//   不是只 cycle 0 拉一下就好。
// =============================================================================

`timescale 1ns/1ps

module tb_merge_tree;
    import trapezoid_pkg::*;

    logic                                    clk = 0;
    logic                                    rst_n;
    logic                                    en;
    logic signed [N_MUL_ROW-1:0][PROD_W-1:0] partials;
    logic signed [ACC_W-1:0]                 sum;

    int fails;
    int expected;
    int i;

    // 500 MHz → period 2 ns
    always #1 clk = ~clk;

    merge_tree_radix16 dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (en),
        .partials (partials),
        .sum      (sum)
    );

    // 把 16 個 partials 設為同一個值(所有 entry 一樣)
    task set_all(input signed [PROD_W-1:0] v);
        for (i = 0; i < N_MUL_ROW; i = i + 1)
            partials[i] = v;
    endtask

    // 把 16 個 partials 設為 1..16(遞增序列)
    task set_one_to_sixteen;
        for (i = 0; i < N_MUL_ROW; i = i + 1)
            partials[i] = i + 1;  // [1, 2, 3, ..., 16]
    endtask

    // 把 16 個 partials 設為正負交替:[+1, -1, +2, -2, ..., +8, -8]
    // sum = 0
    task set_alternating;
        for (i = 0; i < N_MUL_ROW; i = i + 1) begin
            if (i % 2 == 0)
                partials[i] =  ((i/2) + 1);
            else
                partials[i] = -((i/2) + 1);
        end
    endtask

    // 等 4 個 posedge clk(tree pipeline latency)
    task wait_pipeline;
        repeat (4) @(posedge clk);
        #0.1;  // settle
    endtask

    `define CHECK(cond, msg) \
        if (!(cond)) begin \
            $display("[FAIL] %s: sum=%0d expected=%0d", msg, sum, expected); \
            fails = fails + 1; \
        end else begin \
            $display("[PASS] %s: sum=%0d", msg, sum); \
        end

    initial begin
        $dumpfile("tb_merge_tree.vcd");
        $dumpvars(0, tb_merge_tree);
        fails = 0;

        // 初始化
        rst_n = 0;
        en = 0;
        set_all(16'sd0);
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;

        // ---------------------------------------------------------
        // T1: reset 後 sum = 0
        // ---------------------------------------------------------
        @(posedge clk); #0.1;
        expected = 0;
        `CHECK(sum === 32'sd0, "T1 reset sum=0")

        // ---------------------------------------------------------
        // T2: 全 1 → sum = 16
        //     partials = [1, 1, ..., 1] (16 個)
        // ---------------------------------------------------------
        @(negedge clk);
        set_all(16'sd1);
        en = 1;
        wait_pipeline;
        expected = 16;
        `CHECK(sum === 32'sd16, "T2 all-ones sum=16")

        // ---------------------------------------------------------
        // T3: 全 -1 → sum = -16
        // ---------------------------------------------------------
        @(negedge clk);
        set_all(-16'sd1);
        en = 1;
        wait_pipeline;
        expected = -16;
        `CHECK(sum === -32'sd16, "T3 all-neg-one sum=-16")

        // ---------------------------------------------------------
        // T4: 1..16 → sum = 1+2+...+16 = 136
        // ---------------------------------------------------------
        @(negedge clk);
        set_one_to_sixteen;
        en = 1;
        wait_pipeline;
        expected = 136;
        `CHECK(sum === 32'sd136, "T4 1..16 sum=136")

        // ---------------------------------------------------------
        // T5: 邊界值 INT16_MAX (= 32767) × 16 = 524272
        //     INT32 上限 2^31 - 1 = 2,147,483,647,524272 遠遠在範圍內
        // ---------------------------------------------------------
        @(negedge clk);
        set_all(16'sd32767);   // INT16_MAX
        en = 1;
        wait_pipeline;
        expected = 16 * 32767;  // = 524272
        `CHECK(sum === 32'sd524272, "T5 INT16_MAX*16 sum=524272 (no overflow)")

        // ---------------------------------------------------------
        // T6: 正負交替 → sum = 0
        //     [+1, -1, +2, -2, ..., +8, -8] → 各對相消 = 0
        // ---------------------------------------------------------
        @(negedge clk);
        set_alternating;
        en = 1;
        wait_pipeline;
        expected = 0;
        `CHECK(sum === 32'sd0, "T6 alternating signs sum=0")

        // ---------------------------------------------------------
        // (可選 T7: latency check — 確認真的 4 cycle latency)
        // 留給你自己加。提示:partials 變了之後,sum 應該要 4 cycle 後才反應。
        // ---------------------------------------------------------

        // ---------------------------------------------------------
        // 結束
        // ---------------------------------------------------------
        @(negedge clk); en = 0;
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

    // Timeout 防呆
    initial begin
        #50000;
        $display("[ERR] timeout");
        $finish;
    end

endmodule
