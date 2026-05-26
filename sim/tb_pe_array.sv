// =============================================================================
// tb_pe_array.sv — 16×16 PE Array 整合測試 (Dense IP + B forwarding chain)
// =============================================================================
// 測 module: rtl/pe/pe_array.sv
//   內部含: 16 條 pe_row (各自 16 mul + radix-16 tree + INT32 acc) +
//           B 跨 row vertical forwarding chain (paper Fig 7 step ④)
// Owner: 黃妍心
//
// 跑法: make tb_pe_array
// 看波形: gtkwave tb_pe_array.vcd
//
// === 測什麼(Dense IP only,K=1 跟 K=2)===
//   T1: reset 後 c_valid 全 0, c_out 全 0
//   T2: K=1 uniform — 全 row a=1, b=1 → 每 row c_out = 16
//       驗 B forwarding chain 把 B 傳到 16 條 row (每 row 都收到 B)
//   T3: K=1 per-row A — row r 的 a 全填 (r+1),b=1 → row r c_out = (r+1)*16
//       驗 A row-stationary,每 row 用自己的 A(沒被 broadcast 同一份)
//   T4: K=2 累加 — 全 row a=1,b 兩拍餵 B0=2 / B1=3 → 每 row c_out = 80
//       驗 K-tile 多次累加 + B forwarding 跨 cycle 都對
//
// === 不測(等 sliced tree 整合進 pe_row 後再加)===
//   ❌ TrIP sub-tree slicing(cut_after ≠ 0 那條路徑,pe_row 還沒接 sliced tree)
//   ❌ per-row 控制訊號(目前 in_valid/acc_clear/acc_dump broadcast,Phase 2 才 per-row)
//   ❌ MFIU / dist_net 介接(那些 module 還是 stub)
//
// === Pipeline timing(7-stage pe_row + B chain 15-cycle 累計延遲)===
//   B 從 row 0 進,每 cycle 往下傳一條:row r 在 cycle r 才看到 b_vec_top 在 cycle 0 的值
//   每條 row 的 dot product pipeline 7 stage:S1 latch → S2 mul → S3-S6 tree → S7 acc
//
//   結果:row r 的 acc 在 posedge (r+7) 抓到 sum
//         row 15 最慢,posedge 22 才抓到 sum
//
//   廣播 acc_dump 必須等 row 15 完成才拉:
//     K=1: 在 posedge 22 採樣到 acc_dump=1
//     K=2: 在 posedge 23 採樣到 acc_dump=1 (row 15 的第 2 次累加完才行)
//
//   tb 用 negedge driving,acc_dump=1 拉在 dump 前 1 拍的 negedge,
//   再 `@(negedge clk)` 走過下一個 posedge 後 c_out 就有效。
//
//   K=1 / K=2 共用 sequence:
//     negedge 0: 餵第 1 拍(in_valid=1 + acc_clear=1)
//     negedge 1: K=1 → in_valid=0; K=2 → 餵第 2 拍 (in_valid=1)
//     negedge 2: (K=2) in_valid=0
//     等 20 個 negedge → 到 negedge 21 (K=1) 或 negedge 22 (K=2)
//     acc_dump = 1
//     @(negedge clk) → posedge 22 (K=1) 或 23 (K=2) 採樣 acc_dump
//     acc_dump = 0,check c_out
// =============================================================================

`timescale 1ns/1ps

module tb_pe_array;
    import trapezoid_pkg::*;

    // ============================================================
    // DUT signals
    // ============================================================
    logic                                                          clk = 0;
    logic                                                          rst_n;
    logic [1:0]                                                    dataflow_sel;
    logic                                                          in_valid;
    logic                                                          acc_clear;
    logic                                                          acc_dump;
    logic signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0]         a_grid;
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0]                       b_vec_top;
    logic        [N_PE_ROW-1:0]                                    c_valid;
    logic signed [N_PE_ROW-1:0][ACC_W-1:0]                         c_out;

    int fails;
    int r, k;

    // 500 MHz period
    always #1 clk = ~clk;

    // ============================================================
    // DUT instantiation
    // ============================================================
    pe_array dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .dataflow_sel(dataflow_sel),
        .in_valid    (in_valid),
        .acc_clear   (acc_clear),
        .acc_dump    (acc_dump),
        .a_grid      (a_grid),
        .b_vec_top   (b_vec_top),
        .c_valid     (c_valid),
        .c_out       (c_out)
    );

    // ============================================================
    // Helper tasks
    // ============================================================

    // 把 a_grid 全 row × 全 element 填同一 INT8 值
    //   用 replication 避開 iverilog 對「3D packed array 雙變數 index 賦值」的限制
    task set_a_all(input signed [DATA_W-1:0] v);
        a_grid = {N_TOTAL_MAC{v}};
    endtask

    // row r 的 a 全填 (r+1):row 0=[1,1,...], row 1=[2,2,...], ..., row 15=[16,16,...]
    //   用 row-level 賦值 + replication
    task set_a_per_row_ascending;
        logic signed [DATA_W-1:0] val;
        for (r = 0; r < N_PE_ROW; r = r + 1) begin
            val = r + 1;
            a_grid[r] = {N_MUL_ROW{val}};
        end
    endtask

    // b_vec_top 全 16 個 element 填同一值
    task set_b_top_all(input signed [DATA_W-1:0] v);
        for (k = 0; k < N_MUL_ROW; k = k + 1)
            b_vec_top[k] = v;
    endtask

    // 驗單一 row 的 c_out + c_valid
    task check_row(
        input int                       row,
        input logic signed [ACC_W-1:0]  exp,
        input string                    msg
    );
        if (c_valid[row] !== 1'b1) begin
            $display("[FAIL] %s: row %0d c_valid=%b (expected 1)",
                     msg, row, c_valid[row]);
            fails = fails + 1;
        end else if (c_out[row] !== exp) begin
            $display("[FAIL] %s: row %0d c_out=%0d (expected %0d)",
                     msg, row, c_out[row], exp);
            fails = fails + 1;
        end else begin
            $display("[PASS] %s: row %0d c_out=%0d", msg, row, c_out[row]);
        end
    endtask

    // K=1 single-tile sequence:
    //   呼叫前要先 set 好 a_grid + b_vec_top
    //   呼叫後 c_out / c_valid 已經是 dump 結果(可以直接 check)
    task run_k1_then_dump;
        @(negedge clk);
        in_valid  = 1;
        acc_clear = 1;       // 清前面殘留
        acc_dump  = 0;

        @(negedge clk);
        in_valid  = 0;
        acc_clear = 0;

        repeat (20) @(negedge clk);  // 等 row 15 完成 (negedge 1 → negedge 21)
        acc_dump = 1;

        @(negedge clk);              // posedge 22 採樣 acc_dump → c_out 有效
        acc_dump = 0;
        #0.1;
    endtask

    // ============================================================
    // 主測試流程
    // ============================================================
    initial begin
        $dumpfile("tb_pe_array.vcd");
        $dumpvars(0, tb_pe_array);
        fails = 0;

        // 初始化
        rst_n        = 0;
        in_valid     = 0;
        acc_clear    = 0;
        acc_dump     = 0;
        dataflow_sel = MODE_DENSE_IP;
        set_a_all(8'sd0);
        set_b_top_all(8'sd0);

        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;

        // ============================================================
        // T1: Reset 後 c_valid 全 0, c_out 全 0
        // ============================================================
        @(posedge clk); #0.1;
        if (c_valid === '0 && c_out === '0) begin
            $display("[PASS] T1 reset: all c_valid=0, c_out=0");
        end else begin
            $display("[FAIL] T1 reset: c_valid=%b c_out=%h",
                     c_valid, c_out);
            fails = fails + 1;
        end

        // ============================================================
        // T2: Dense IP K=1, 全 row uniform a=1 b=1 → 每 row c_out=16
        //     驗:B forwarding chain 把 B 傳到所有 16 row
        //         (如果 chain 沒接好,某些 row 會收到 0,c_out 會 < 16)
        // ============================================================
        set_a_all(8'sd1);
        set_b_top_all(8'sd1);
        run_k1_then_dump;

        for (r = 0; r < N_PE_ROW; r = r + 1) begin
            check_row(r, 32'sd16,
                      $sformatf("T2 K=1 uniform row%0d (a=1·b=1·16=16)", r));
        end

        // ============================================================
        // T3: Dense IP K=1, row r 用 a=(r+1),b=1 → row r c_out=(r+1)*16
        //     驗:A row-stationary,每 row 拿到自己的 a_grid[r],
        //         不是被同一份 A 廣播(廣播的話全 row c_out 都會一樣)
        // ============================================================
        set_a_per_row_ascending;
        set_b_top_all(8'sd1);
        run_k1_then_dump;

        for (r = 0; r < N_PE_ROW; r = r + 1) begin
            check_row(r, (r + 1) * 16,
                      $sformatf("T3 K=1 per-row row%0d (a=%0d·b=1·16=%0d)",
                                r, r + 1, (r + 1) * 16));
        end

        // ============================================================
        // T4: Dense IP K=2 累加,全 row a=1
        //     cycle 0 餵 B0=2,cycle 1 餵 B1=3,cycle 2 in_valid=0
        //     row r 累加兩次:16*1*2 + 16*1*3 = 32 + 48 = 80
        //
        //     驗:
        //       - K-tile 跨 cycle 累加(acc + tree_sum 兩次)
        //       - B forwarding 跨 cycle:row r 在 cycle r 收到 B0,
        //         cycle r+1 收到 B1,各自跟 a 做 mul
        //
        //     時序:row 15 第 2 次 acc 在 posedge 23,所以 dump 在 negedge 22
        // ============================================================
        @(negedge clk);
        set_a_all(8'sd1);
        set_b_top_all(8'sd2);    // B0 = 2
        in_valid  = 1;
        acc_clear = 1;
        acc_dump  = 0;

        @(negedge clk);
        set_b_top_all(8'sd3);    // B1 = 3,in_valid 還是 1
        in_valid  = 1;
        acc_clear = 0;

        @(negedge clk);
        in_valid  = 0;

        repeat (20) @(negedge clk);  // negedge 2 → negedge 22
        acc_dump = 1;

        @(negedge clk);              // posedge 23 採樣
        acc_dump = 0;
        #0.1;

        for (r = 0; r < N_PE_ROW; r = r + 1) begin
            check_row(r, 32'sd80,
                      $sformatf("T4 K=2 row%0d (16*(2+3)=80)", r));
        end

        // ============================================================
        // 結束
        // ============================================================
        @(negedge clk);
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
        #100000;
        $display("[ERR] timeout");
        $finish;
    end

endmodule
