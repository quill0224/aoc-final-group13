// =============================================================================
// tb_pe_row.sv — PE row 基本功能測試 (Dense IP, K=16 single-tile)
// =============================================================================
// 測 module: rtl/pe/pe_row.v
//   內部含: 16 個 mac_unit + radix-16 merge tree + accumulator + B-forwarding
// Owner: 黃妍心
//
// 跑法: make tb_pe_row
// 看波形: gtkwave tb_pe_row.vcd
//
// 測什麼 (抗架構變動原則 — 只測核心 dot product 行為):
//   T1: reset 後 c_valid=0, c_out=0
//   T2: a=[1,1,...,1], b=[1,1,...,1] → c_out = 16
//   T3: a=[1,2,...,16], b=[16,15,...,1] → c_out = 816
//        (1*16 + 2*15 + ... + 16*1 = 17*sum(1..16) - sum(1²..16²)
//                                  = 17*136 - 1496 = 2312 - 1496 = 816)
//   T4: acc_clear 行為 — 前一個 dot product 不會污染後一個
//
// 不測 (留給 tb_pe_array.sv,等架構穩定再說):
//   ❌ B vertical forwarding (b_vec_out 的輸出時序)
//   ❌ K > 16 跨 K-tile 累加
//   ❌ multi-row 行為
//
// 時序 (Pipeline 7 stages):
//   pe_row 從 in_valid 拉起算 7 拍後 c_out 才有結果。
//
//   cycle 0:  in_valid=1, a_vec, b_vec_in 餵進去
//   cycle 1:  S1 latch (a_q, b_q 抓到值)
//   cycle 2:  S2 mul (partials 抓到值)
//   cycle 3:  S3 tree stage 1
//   cycle 4:  S4 tree stage 2
//   cycle 5:  S5 tree stage 3
//   cycle 6:  S6 tree stage 4 → tree_valid=1, tree_sum 有值
//             ← 此拍要拉 acc_dump=1 (跟 tree_valid 對齊)
//   cycle 7:  c_out 抓到 acc + tree_sum,c_valid=1
//
//   acc_clear 對齊到 cycle 0 (跟 in_valid 同拍),確保 acc 在 cycle 1 清為 0
// =============================================================================

`timescale 1ns/1ps

module tb_pe_row;
    import trapezoid_pkg::*;

    logic                                    clk = 0;
    logic                                    rst_n;
    logic                                    in_valid;
    logic                                    acc_clear;
    logic                                    acc_dump;
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] a_vec;
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] b_vec_in;
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] b_vec_out;
    logic                                    b_valid_out;
    logic                                    c_valid;
    logic signed [ACC_W-1:0]                 c_out;

    int fails;
    int expected;
    int i;

    // 500 MHz → 2 ns period
    always #1 clk = ~clk;

    pe_row dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_valid    (in_valid),
        .acc_clear   (acc_clear),
        .acc_dump    (acc_dump),
        .a_vec       (a_vec),
        .b_vec_in    (b_vec_in),
        .b_vec_out   (b_vec_out),
        .b_valid_out (b_valid_out),
        .c_valid     (c_valid),
        .c_out       (c_out)
    );

    // 把 a_vec / b_vec_in 全填同一值
    task set_a_all(input signed [DATA_W-1:0] v);
        for (i = 0; i < N_MUL_ROW; i = i + 1) a_vec[i] = v;
    endtask
    task set_b_all(input signed [DATA_W-1:0] v);
        for (i = 0; i < N_MUL_ROW; i = i + 1) b_vec_in[i] = v;
    endtask

    // a = [1, 2, ..., 16]
    task set_a_ascending;
        for (i = 0; i < N_MUL_ROW; i = i + 1) a_vec[i] = i + 1;
    endtask
    // b = [16, 15, ..., 1]
    task set_b_descending;
        for (i = 0; i < N_MUL_ROW; i = i + 1) b_vec_in[i] = N_MUL_ROW - i;
    endtask

    // 驅動 1 拍 in_valid + 等 6 拍 + 拉 acc_dump + 等 1 拍 check
    // 這是「K=16 single tile」的標準 sequence
    task run_dot_product(input do_clear);
        @(negedge clk);
        in_valid  = 1;
        acc_clear = do_clear;
        acc_dump  = 0;

        @(negedge clk);   // cycle 1
        in_valid  = 0;
        acc_clear = 0;

        repeat (5) @(negedge clk);  // cycle 2-6

        // cycle 6:此拍 tree_valid=1,要拉 acc_dump
        acc_dump = 1;

        @(negedge clk);   // cycle 7:c_out 應該已抓到結果
        acc_dump = 0;
        #0.1;             // settle
    endtask

    `define CHECK(cond, msg) \
        if (!(cond)) begin \
            $display("[FAIL] %s: c_out=%0d expected=%0d c_valid=%0b", \
                     msg, c_out, expected, c_valid); \
            fails = fails + 1; \
        end else begin \
            $display("[PASS] %s: c_out=%0d c_valid=%0b", msg, c_out, c_valid); \
        end

    initial begin
        $dumpfile("tb_pe_row.vcd");
        $dumpvars(0, tb_pe_row);
        fails = 0;

        // 初始化
        rst_n = 0;
        in_valid = 0; acc_clear = 0; acc_dump = 0;
        set_a_all(8'sd0);
        set_b_all(8'sd0);
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;

        // ---------------------------------------------------------
        // T1: reset 後 c_valid=0, c_out=0
        // ---------------------------------------------------------
        @(posedge clk); #0.1;
        expected = 0;
        `CHECK((c_out === 32'sd0) && (c_valid === 1'b0), "T1 reset state")

        // ---------------------------------------------------------
        // T2: a=[1,1,...,1] · b=[1,1,...,1] = 16
        //     ∑_{i=0..15} 1*1 = 16
        // ---------------------------------------------------------
        set_a_all(8'sd1);
        set_b_all(8'sd1);
        run_dot_product(1);  // acc_clear 同步拉,清前面殘留
        expected = 16;
        `CHECK(c_out === 32'sd16, "T2 ones-dot-ones = 16")

        // ---------------------------------------------------------
        // T3: a=[1,2,...,16] · b=[16,15,...,1] = 816
        //     ∑_{i=1..16} i*(17-i) = 17*∑i - ∑i² = 17*136 - 1496 = 816
        // ---------------------------------------------------------
        set_a_ascending;
        set_b_descending;
        run_dot_product(1);
        expected = 816;
        `CHECK(c_out === 32'sd816, "T3 [1..16]·[16..1] = 816")

        // ---------------------------------------------------------
        // T4: acc_clear 行為 — 連跑兩個 dot product,各自獨立
        //     先跑 T2 (=16),再跑 T2 (=16),但中間 acc_clear,
        //     確認第二次結果還是 16 (沒被前面累加)
        // ---------------------------------------------------------
        set_a_all(8'sd1);
        set_b_all(8'sd1);
        run_dot_product(1);  // 第一次,acc_clear
        // 不檢查第一次(T2 已測過),直接第二次
        run_dot_product(1);  // 第二次,再 acc_clear
        expected = 16;
        `CHECK(c_out === 32'sd16, "T4 acc_clear isolates between dot products")

        // ---------------------------------------------------------
        // 結束
        // ---------------------------------------------------------
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
