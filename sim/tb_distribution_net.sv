// =============================================================================
// tb_distribution_net.sv — Phase 1 (Dense IP) Identity Pass-Through unit test
// =============================================================================
// 測 module: rtl/dist/distribution_net.sv
// Owner: QuillQ (王柏弘)
//
// 跑法: make tb_dist
// 看波形: gtkwave tb_distribution_net.vcd
//
// 測什麼 (Phase 1 dense pass-through 範圍):
//   驗證:
//     pe_a_grid === a_grid_in    對所有 256 個 (r, m)  [16×16 grid]
//     pe_b_top  === b_vec_in_top 對所有 16 個 m         [single row top, B-chain]
//
//   T1: 全 0 input          → 全 0 output                  (基本 sanity)
//   T2: 全 +1 input         → 全 +1 output                 (uniform positive)
//   T3: 全 -1 input         → 全 -1 output                 (sign-extend 檢查)
//   T4: Linear pattern       → 256+16 條 wire 各自獨立     (抓 wire 串到別格的 bug)
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
//        // Error: "A reference to a wire or reg (`r') is not allowed in
//        //        a constant expression."
//
// 解法 — Row Temporary Pattern (本檔內 A grid loop 用這招):
//
//     logic signed [N_MUL_ROW-1:0][DATA_W-1:0] row_tmp;
//     for (m = 0; m < 16; m = m + 1) row_tmp[m] = val;  // 單變數 index ✅
//     for (r = 0; r < 16; r = r + 1) a_grid_in[r] = row_tmp;  // 單變數 index ✅
//
// B 路徑是 1D packed (`[N_MUL_ROW-1:0][DATA_W-1:0]`)，單變數 index 直接 OK，
// 不用 row temp。
// =============================================================================

`timescale 1ns/1ps

module tb_distribution_net;
    import trapezoid_pkg::*;

    // ───────────────────────────────────────────────────────────
    // DUT 訊號
    //   A 路徑: 16×16 grid    (對齊 pe_array.a_grid)
    //   B 路徑: 16 single row (對齊 pe_array.b_vec_top, chain forwarding)
    // ───────────────────────────────────────────────────────────
    logic                                                  clk = 0;
    logic                                                  rst_n;
    logic signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0] a_grid_in;
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0]               b_vec_in_top;
    logic signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0] pe_a_grid;
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0]               pe_b_top;

    int fails;
    int r;
    int m;

    // Row temp 給 A grid 用 (繞 iverilog 2D packed 雙變數 index 限制)
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] row_a_tmp;

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
        .clk          (clk),
        .rst_n        (rst_n),
        .a_grid_in    (a_grid_in),
        .b_vec_in_top (b_vec_in_top),
        .pe_a_grid    (pe_a_grid),
        .pe_b_top     (pe_b_top)
    );

    // ───────────────────────────────────────────────────────────
    // Helper task: set_all_uniform
    //   把整 A grid + B top 設成 (av, bv)
    //   A grid 走 row temp 兩階段; B 直接 1D 單變數 index loop
    // ───────────────────────────────────────────────────────────
    task set_all_uniform(input signed [DATA_W-1:0] av,
                         input signed [DATA_W-1:0] bv);
        // A grid: row temp 兩階段組
        for (m = 0; m < N_MUL_ROW; m = m + 1)
            row_a_tmp[m] = av;
        for (r = 0; r < N_PE_ROW; r = r + 1)
            a_grid_in[r] = row_a_tmp;
        // B top: 1D 單變數 index，直接寫
        for (m = 0; m < N_MUL_ROW; m = m + 1)
            b_vec_in_top[m] = bv;
    endtask

    // ───────────────────────────────────────────────────────────
    // Helper task: check_pass_through
    //   比對:
    //     pe_a_grid === a_grid_in     對所有 (r, m)  256 cells
    //     pe_b_top  === b_vec_in_top  對所有 m       16 cells
    //   有 mismatch 印 detail (ok 變 0)，全 match 才 PASS
    // ───────────────────────────────────────────────────────────
    task check_pass_through(input [255:0] testname);
        logic ok;
        logic signed [N_MUL_ROW-1:0][DATA_W-1:0] row_a_pe;
        logic signed [N_MUL_ROW-1:0][DATA_W-1:0] row_a_in;
        ok = 1;
        // ── A grid 256 cells ──
        for (r = 0; r < N_PE_ROW; r = r + 1) begin
            row_a_pe = pe_a_grid[r];
            row_a_in = a_grid_in[r];
            for (m = 0; m < N_MUL_ROW; m = m + 1) begin
                if (row_a_pe[m] !== row_a_in[m]) begin
                    $display("  [MISMATCH a] [%0d][%0d] pe=%0d expected=%0d",
                             r, m, row_a_pe[m], row_a_in[m]);
                    ok = 0;
                end
            end
        end
        // ── B top 16 cells ──
        for (m = 0; m < N_MUL_ROW; m = m + 1) begin
            if (pe_b_top[m] !== b_vec_in_top[m]) begin
                $display("  [MISMATCH b] [%0d] pe=%0d expected=%0d",
                         m, pe_b_top[m], b_vec_in_top[m]);
                ok = 0;
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

        // 初始化 (整 grid + top 用 '0 一次清掉)
        rst_n = 0;
        a_grid_in = '0;
        b_vec_in_top = '0;
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
        // T4: Linear pattern — A 256 個位置各自獨立, B 16 個位置各自獨立
        //   A: a[r][m] = (r*16 + m) - 128    範圍 [-128, +127]
        //   B: b[m]    = m * 8 - 64          範圍 [-64, +56] (簡單 linear)
        //   抓 typo 串到別格的 bug
        // ─────────────────────────────────────────────────────
        // A grid: row temp 兩階段
        for (r = 0; r < N_PE_ROW; r = r + 1) begin
            for (m = 0; m < N_MUL_ROW; m = m + 1) begin
                cell_val = (r * N_MUL_ROW + m) - 128;
                row_a_tmp[m] = cell_val;
            end
            a_grid_in[r] = row_a_tmp;
        end
        // B top: 1D 直接
        for (m = 0; m < N_MUL_ROW; m = m + 1) begin
            cell_val = (m * 8) - 64;
            b_vec_in_top[m] = cell_val;
        end
        #1;
        check_pass_through("T4 linear patterns");

        // ─────────────────────────────────────────────────────
        // T5: INT8 邊界值 (極端位置)
        //   ✅ constant index 兩個變數一起用是 OK 的 (iverilog 接受常數)
        // ─────────────────────────────────────────────────────
        set_all_uniform(8'sd0, 8'sd0);
        a_grid_in[0][0]    =  8'sd127;    // INT8_MAX 對角左上
        a_grid_in[15][15]  = -8'sd128;    // INT8_MIN 對角右下
        b_vec_in_top[0]    =  8'sd127;    // B top 兩端
        b_vec_in_top[15]   = -8'sd128;
        #1;
        check_pass_through("T5 INT8 boundaries");

        // ─────────────────────────────────────────────────────
        // T6: Random pattern
        //   $random 回 32-bit；賦值到 signed [DATA_W-1:0] 會截斷到 -128..127
        //   A 用 row temp 中介; B 直接 1D 寫
        // ─────────────────────────────────────────────────────
        for (r = 0; r < N_PE_ROW; r = r + 1) begin
            for (m = 0; m < N_MUL_ROW; m = m + 1)
                row_a_tmp[m] = $random;
            a_grid_in[r] = row_a_tmp;
        end
        for (m = 0; m < N_MUL_ROW; m = m + 1)
            b_vec_in_top[m] = $random;
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
