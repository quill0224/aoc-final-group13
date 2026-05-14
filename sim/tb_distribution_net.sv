// =============================================================================
// tb_distribution_net.sv — Phase 1 (Dense IP) Identity Pass-Through unit test
// =============================================================================
// 測 module: rtl/dist/distribution_net.sv
// Owner: QuillQ (施柏安)
//
// 跑法: make tb_dist
// 看波形: gtkwave tb_distribution_net.vcd
//
// 測什麼 (Phase 1 dense pass-through 範圍):
//   驗證 pe_a_grid === a_grid_in 跟 pe_b_grid === b_grid_in 對所有 256 個 (r, m)。
//
//   T1: 全 0 input          → 全 0 output                  (基本 sanity)
//   T2: 全 +1 input         → 全 +1 output                 (uniform positive)
//   T3: 全 -1 input         → 全 -1 output                 (sign-extend 檢查)
//   T4: Linear pattern       → 256 條 wire 各自獨立        (抓 wire 串到別格的 bug)
//        a[r][m] = (r*16 + m) - 128                          範圍 [-128, +127]
//        b[r][m] = -a[r][m]
//   T5: INT8 邊界值          → +127 / -128 不截斷
//   T6: Random pattern       → 用 $random 抓漏網
//
// 時序:
//   dist net Phase 1 是純組合 (0 cycle latency)，
//   設 input 後 #1 ns 立刻 check output，不用 wait posedge clk。
//
// =============================================================================
// ⚠️ iverilog 踩坑點：2D packed array 雙變數 index 不支援
// =============================================================================
// a_grid_in 宣告為 `logic signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0]`
// (2D packed)。iverilog (-g2012) 不允許「兩個變數同時 index」:
//
//     ❌ for (r=0; r<16; r++) for (m=0; m<16; m++)
//            a_grid_in[r][m] = val;
//        // 錯誤: "A reference to a wire or reg (`r') is not allowed in
//        //        a constant expression."
//
// 解法 — Row Temporary Pattern (本檔內每個 helper / loop 都這樣寫):
//
//     logic signed [N_MUL_ROW-1:0][DATA_W-1:0] row_tmp;
//     for (m = 0; m < 16; m = m + 1) row_tmp[m] = val;  // 單變數 index ✅
//     for (r = 0; r < 16; r = r + 1) a_grid_in[r] = row_tmp;  // 單變數 index ✅
//
// 兩階段都是「單一變數 index 在 packed 上」, iverilog 接受。
// Iris 的 tb 沒踩到是因為她 module 只用 1D packed (e.g. `a_vec[i]`),
// 我們 dist net 是 2D packed (per-row × per-mul) 才會撞。
// =============================================================================

`timescale 1ns/1ps

module tb_distribution_net;
    import trapezoid_pkg::*;

    // ───────────────────────────────────────────────────────────
    // DUT 訊號
    // ───────────────────────────────────────────────────────────
    logic                                                  clk = 0;
    logic                                                  rst_n;
    logic signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0] a_grid_in;
    logic signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0] b_grid_in;
    logic signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0] pe_a_grid;
    logic signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0] pe_b_grid;

    int fails;
    int r;
    int m;

    // Row temporaries (繞 iverilog 2D packed 雙變數 index 限制)
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] row_a_tmp;
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] row_b_tmp;

    // 單一 cell 的 INT8 暫存 (T4 linear pattern 計算用)
    logic signed [DATA_W-1:0] cell_val;

    // ───────────────────────────────────────────────────────────
    // 500 MHz 時脈 (跟 Iris 其他 tb 對齊；Phase 1 純組合用不到，給 dump 用)
    // ───────────────────────────────────────────────────────────
    always #1 clk = ~clk;

    // ───────────────────────────────────────────────────────────
    // DUT instantiate
    // ───────────────────────────────────────────────────────────
    distribution_net dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .a_grid_in  (a_grid_in),
        .b_grid_in  (b_grid_in),
        .pe_a_grid  (pe_a_grid),
        .pe_b_grid  (pe_b_grid)
    );

    // ───────────────────────────────────────────────────────────
    // Helper task: set_all_uniform
    //   把整 grid 設成 (av, bv) — 用 row temp 兩階段組
    // ───────────────────────────────────────────────────────────
    task set_all_uniform(input signed [DATA_W-1:0] av,
                         input signed [DATA_W-1:0] bv);
        // 階段 1: 在 row temp 用單變數 index 組好一條 row
        for (m = 0; m < N_MUL_ROW; m = m + 1) begin
            row_a_tmp[m] = av;
            row_b_tmp[m] = bv;
        end
        // 階段 2: 用單變數 index 把 row temp 寫進 16 條 row
        for (r = 0; r < N_PE_ROW; r = r + 1) begin
            a_grid_in[r] = row_a_tmp;
            b_grid_in[r] = row_b_tmp;
        end
    endtask

    // ───────────────────────────────────────────────────────────
    // Helper task: check_pass_through
    //   比對 pe_a/b_grid === a/b_grid_in 對所有 256 個 cell
    //   用 row temp 抓整 row 再單變數 index 比 cell
    // ───────────────────────────────────────────────────────────
    task check_pass_through(input [255:0] testname);
        logic ok;
        logic signed [N_MUL_ROW-1:0][DATA_W-1:0] row_a_pe;
        logic signed [N_MUL_ROW-1:0][DATA_W-1:0] row_a_in;
        logic signed [N_MUL_ROW-1:0][DATA_W-1:0] row_b_pe;
        logic signed [N_MUL_ROW-1:0][DATA_W-1:0] row_b_in;
        ok = 1;
        for (r = 0; r < N_PE_ROW; r = r + 1) begin
            // 用單變數 index 抓整 row 進 temp
            row_a_pe = pe_a_grid[r];
            row_a_in = a_grid_in[r];
            row_b_pe = pe_b_grid[r];
            row_b_in = b_grid_in[r];
            // 再用單變數 index 比裡面 16 個 cell
            for (m = 0; m < N_MUL_ROW; m = m + 1) begin
                if (row_a_pe[m] !== row_a_in[m]) begin
                    $display("  [MISMATCH a] [%0d][%0d] pe=%0d expected=%0d",
                             r, m, row_a_pe[m], row_a_in[m]);
                    ok = 0;
                end
                if (row_b_pe[m] !== row_b_in[m]) begin
                    $display("  [MISMATCH b] [%0d][%0d] pe=%0d expected=%0d",
                             r, m, row_b_pe[m], row_b_in[m]);
                    ok = 0;
                end
            end
        end
        if (ok) $display("[PASS] %0s", testname);
        else begin
            $display("[FAIL] %0s", testname);
            fails = fails + 1;
        end
    endtask

    // ───────────────────────────────────────────────────────────
    // Main test sequence
    // ───────────────────────────────────────────────────────────
    initial begin
        $dumpfile("tb_distribution_net.vcd");
        $dumpvars(0, tb_distribution_net);
        fails = 0;

        // 初始化 (整 grid 用 '0 一次清掉 — 不會踩雙 index 雷)
        rst_n = 0;
        a_grid_in = '0;
        b_grid_in = '0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;

        // ─────────────────────────────────────────────────────
        // T1: 全 0 → 全 0
        // ─────────────────────────────────────────────────────
        set_all_uniform(8'sd0, 8'sd0);
        #1;
        check_pass_through("T1 all zeros");

        // ─────────────────────────────────────────────────────
        // T2: 全 +1 → 全 +1
        // ─────────────────────────────────────────────────────
        set_all_uniform(8'sd1, 8'sd1);
        #1;
        check_pass_through("T2 all +1");

        // ─────────────────────────────────────────────────────
        // T3: 全 -1 → 全 -1 (sign-extend 檢查)
        //   INT8 -1 = 8'hFF；若任何位置 unsigned 處理會看到 +255 → mismatch
        // ─────────────────────────────────────────────────────
        set_all_uniform(-8'sd1, -8'sd1);
        #1;
        check_pass_through("T3 all -1 signed");

        // ─────────────────────────────────────────────────────
        // T4: Linear pattern — 256 個位置各自獨立 (抓 typo 串到別格的 bug)
        //   a[r][m] = (r*16 + m) - 128    範圍 [-128, +127]
        //   b[r][m] = -a[r][m]
        //
        //   ⚠️ 兩個變數 index 不能直接寫 a_grid_in[r][m]，
        //   用 row_a_tmp 中介 (跟 set_all_uniform 同一招)
        // ─────────────────────────────────────────────────────
        for (r = 0; r < N_PE_ROW; r = r + 1) begin
            for (m = 0; m < N_MUL_ROW; m = m + 1) begin
                cell_val = (r * N_MUL_ROW + m) - 128;
                row_a_tmp[m] =  cell_val;
                row_b_tmp[m] = -cell_val;
            end
            a_grid_in[r] = row_a_tmp;
            b_grid_in[r] = row_b_tmp;
        end
        #1;
        check_pass_through("T4 linear -128..127");

        // ─────────────────────────────────────────────────────
        // T5: INT8 邊界值 (極端對角線)
        //   ✅ constant index 兩個變數一起用是 OK 的 (iverilog 接受常數)
        // ─────────────────────────────────────────────────────
        set_all_uniform(8'sd0, 8'sd0);
        a_grid_in[0][0]   =  8'sd127;    // INT8_MAX
        a_grid_in[15][15] = -8'sd128;    // INT8_MIN
        b_grid_in[0][15]  = -8'sd128;
        b_grid_in[15][0]  =  8'sd127;
        #1;
        check_pass_through("T5 INT8 boundaries");

        // ─────────────────────────────────────────────────────
        // T6: Random pattern
        //   $random 回 32-bit；賦值到 signed [DATA_W-1:0] 會截斷到 -128..127
        //   同樣用 row_a_tmp 中介
        // ─────────────────────────────────────────────────────
        for (r = 0; r < N_PE_ROW; r = r + 1) begin
            for (m = 0; m < N_MUL_ROW; m = m + 1) begin
                row_a_tmp[m] = $random;
                row_b_tmp[m] = $random;
            end
            a_grid_in[r] = row_a_tmp;
            b_grid_in[r] = row_b_tmp;
        end
        #1;
        check_pass_through("T6 random pattern");

        // ─────────────────────────────────────────────────────
        // Summary
        // ─────────────────────────────────────────────────────
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
        #10000;
        $display("[ERR] timeout");
        $finish;
    end

endmodule
