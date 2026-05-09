// =============================================================================
// tb_mac_unit.sv — mac_unit 單元測試 (mul-only,registered output)
// =============================================================================
// 跑法: make tb_mac
// 看波形: gtkwave tb_mac_unit.vcd
//
// 對齊 paper Fig 6:mac_unit 只做 mul,不做 acc。
// (acc 在 pe_row 的 accumulator register,K-tile 結束才 dump)
//
// Timing 紀律:
//   - 所有訊號在 negedge clk 才驅動 (避免跟 FF 採樣 race)
//   - check 在 posedge 後 #0.1 (等 NBA 結算)
//   - mac_unit 是 1-cycle latency:這拍給 a/b/en,下一個 posedge 後 product 出現
// =============================================================================

`timescale 1ns/1ps

module tb_mac_unit;
    reg                 clk = 0;
    reg                 rst_n;
    reg                 en;
    reg signed [7:0]    a;
    reg signed [7:0]    b;
    wire signed [15:0]  product;

    integer fails;
    integer expected;

    // 500 MHz → period 2 ns,1 ns 半週期
    always #1 clk = ~clk;

    mac_unit dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (en),
        .a       (a),
        .b       (b),
        .product (product)
    );

    // 在 negedge 驅動,等 1 個 posedge 後 #0.1 採樣
    task drive(input _en, input signed [7:0] _a, input signed [7:0] _b);
        @(negedge clk);
        en = _en;
        a  = _a;
        b  = _b;
    endtask

    task tick_and_settle;
        @(posedge clk);
        #0.1;
    endtask

    `define CHECK(cond, msg) \
        if (!(cond)) begin \
            $display("[FAIL] %s: product=%0d expected=%0d", msg, product, expected); \
            fails = fails + 1; \
        end else begin \
            $display("[PASS] %s: product=%0d", msg, product); \
        end

    initial begin
        $dumpfile("tb_mac_unit.vcd");
        $dumpvars(0, tb_mac_unit);
        fails = 0;

        // 初始化
        rst_n = 0; en = 0; a = 0; b = 0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;

        // T1: reset 後 product = 0
        @(posedge clk); #0.1;
        expected = 0;
        `CHECK(product === 16'sd0, "T1 reset product=0")

        // T2: 正數 mul
        drive(1, 8'sd7, 8'sd6);   // 7*6 = 42
        tick_and_settle;
        expected = 42;
        `CHECK(product === 16'sd42, "T2 7*6=42")

        // T3: 邊界值正乘正 (127*127 = 16129)
        drive(1, 8'sd127, 8'sd127);
        tick_and_settle;
        expected = 16129;
        `CHECK(product === 16'sd16129, "T3 127*127=16129")

        // T4: 負乘正 (-64 * 2 = -128)
        drive(1, -8'sd64, 8'sd2);
        tick_and_settle;
        expected = -128;
        `CHECK(product === -16'sd128, "T4 -64*2=-128")

        // T5: 負乘負 (-100 * -3 = 300)
        drive(1, -8'sd100, -8'sd3);
        tick_and_settle;
        expected = 300;
        `CHECK(product === 16'sd300, "T5 -100*-3=300")

        // T6: en=0 應保持上一個值 (300)
        drive(0, 8'sd99, 8'sd99);
        tick_and_settle;
        expected = 300;
        `CHECK(product === 16'sd300, "T6 hold when en=0 (still 300)")

        // T7: en=1 重新更新
        drive(1, 8'sd5, 8'sd4);
        tick_and_settle;
        expected = 20;
        `CHECK(product === 16'sd20, "T7 5*4=20 after re-enable")

        // T8: 邊界 -128 * 127 = -16256
        drive(1, -8'sd128, 8'sd127);
        tick_and_settle;
        expected = -16256;
        `CHECK(product === -16'sd16256, "T8 -128*127=-16256")

        // T9: 邊界 -128 * -128 = 16384 (signed INT16 上界 32767,沒問題)
        drive(1, -8'sd128, -8'sd128);
        tick_and_settle;
        expected = 16384;
        `CHECK(product === 16'sd16384, "T9 -128*-128=16384")

        // T10: 任一邊為 0 → product = 0
        drive(1, 8'sd0, 8'sd99);
        tick_and_settle;
        expected = 0;
        `CHECK(product === 16'sd0, "T10 0*99=0")

        // T11: 連續 16 次不同 mul,確認每拍都正確更新
        begin : t11
            integer i;
            for (i = 0; i < 16; i = i + 1) begin
                drive(1, i[7:0], (i+1)[7:0]);
                tick_and_settle;
                expected = i * (i+1);
                if (product !== expected[15:0]) begin
                    $display("[FAIL] T11 iter %0d: %0d*%0d = %0d, got %0d",
                             i, i, i+1, expected, product);
                    fails = fails + 1;
                end
            end
            $display("[PASS] T11 16 sequential muls");
        end

        // T12: rst_n 中途拉低,product 應立刻清 0
        drive(1, 8'sd50, 8'sd50);
        tick_and_settle;
        @(negedge clk); rst_n = 0;
        @(posedge clk); #0.1;
        expected = 0;
        `CHECK(product === 16'sd0, "T12 async reset clears product")
        @(negedge clk); rst_n = 1;

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
        #50000;
        $display("[ERR] timeout");
        $finish;
    end

endmodule
