// =============================================================================
// tb_merge_tree_sliced.sv — Sub-tree slicing reduction tree 單元測試
// =============================================================================
// 測 module: rtl/dist/merge_tree_radix16_sliced.sv
// Owner: 黃妍心 + QuillQ
//
// 跑法: make tb_tree_sliced
// 看波形: gtkwave tb_merge_tree_sliced.vcd
//
// === 測什麼(對應 paper §III.B sub-tree slicing 完整驗證) ===
//   T1: Reset 後輸出全 0
//   T2: Dense IP (cut_after=0) all-1 partials → subtree_sums[15] = 16
//       (退化驗證,確保不切時跟舊版單一 tree 結果一樣)
//   T3: Dense IP, partials=[1..16] → subtree_sums[15] = 136
//   T4: 中間 1 cut (cut_after[7]=1), all-1 partials
//       → subtree_sums[7] = 8, subtree_sums[15] = 8
//   T5: Paper Fig 10 風格 — 3 sub-tree
//       cut_after[0]=1, cut_after[2]=1, cut_after[3]=1,
//       partials = [1,2,3,4,0,0,...,0]
//       → subtree_sums[0] = 1   (C20)
//          subtree_sums[2] = 5   (C21 = 2+3)
//          subtree_sums[3] = 4   (C31)
//          subtree_sums[15] = 0  (剩下 partials 全 0)
//   T6: 全 cut (cut_after = 15'h7FFF) → 16 個獨立 sub-tree
//       每個 subtree_sums[i] = partials[i]
//   T7: Sign handling — 負數 partials,confirm signed math
//   T8: 邊界值 — INT16 max,confirm no overflow at INT32
//
// === Pipeline timing ===
//   4-stage latency,跟舊 tree 一致
//   posedge clk N: 餵 partials + cut_after
//   posedge clk N+4: 輸出 subtree_sums 跟 subtree_valid 有效
//
//   en=1 必須維持 4 拍以上,讓資料推進整條 pipeline
// =============================================================================

`timescale 1ns/1ps

module tb_merge_tree_sliced;
    import trapezoid_pkg::*;

    logic                                    clk = 0;
    logic                                    rst_n;
    logic                                    en;
    logic signed [N_MUL_ROW-1:0][PROD_W-1:0] partials;
    logic        [N_MUL_ROW-2:0]              cut_after;
    logic signed [N_MUL_ROW-1:0][ACC_W-1:0]   subtree_sums;
    logic        [N_MUL_ROW-1:0]              subtree_valid;

    int fails;
    int i;

    // 500 MHz period
    always #1 clk = ~clk;

    merge_tree_radix16_sliced dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .en             (en),
        .partials       (partials),
        .cut_after      (cut_after),
        .subtree_sums   (subtree_sums),
        .subtree_valid  (subtree_valid)
    );

    // ============================================================
    // Helper tasks
    // ============================================================

    // 把 16 個 partials 全設為同一值
    task set_partials_all(input signed [PROD_W-1:0] v);
        for (i = 0; i < N_MUL_ROW; i = i + 1)
            partials[i] = v;
    endtask

    // partials = [1, 2, 3, ..., 16]
    task set_partials_1_to_16;
        for (i = 0; i < N_MUL_ROW; i = i + 1)
            partials[i] = i + 1;
    endtask

    // partials = [1, 2, 3, 4, 0, 0, ..., 0]  (paper Fig 10 風格,前 4 有值)
    task set_partials_fig10;
        partials[0] = 16'sd1;
        partials[1] = 16'sd2;
        partials[2] = 16'sd3;
        partials[3] = 16'sd4;
        for (i = 4; i < N_MUL_ROW; i = i + 1)
            partials[i] = 16'sd0;
    endtask

    // partials = [1, -1, 2, -2, ..., 8, -8]
    task set_partials_alternating;
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
        #0.1;
    endtask

    // 驗 1 個 subtree 結果
    task check_subtree(
        input int                    pos,        // subtree 結尾位置
        input logic                   exp_valid,
        input logic signed [ACC_W-1:0] exp_sum,
        input string                  msg
    );
        if (subtree_valid[pos] !== exp_valid) begin
            $display("[FAIL] %s: subtree_valid[%0d]=%b expected=%b",
                     msg, pos, subtree_valid[pos], exp_valid);
            fails = fails + 1;
        end else if (exp_valid && subtree_sums[pos] !== exp_sum) begin
            $display("[FAIL] %s: subtree_sums[%0d]=%0d expected=%0d",
                     msg, pos, subtree_sums[pos], exp_sum);
            fails = fails + 1;
        end else begin
            $display("[PASS] %s: subtree[%0d] valid=%b sum=%0d",
                     msg, pos, subtree_valid[pos], subtree_sums[pos]);
        end
    endtask

    // ============================================================
    // 主測試流程
    // ============================================================
    initial begin
        $dumpfile("tb_merge_tree_sliced.vcd");
        $dumpvars(0, tb_merge_tree_sliced);
        fails = 0;

        // 初始化
        rst_n = 0;
        en = 0;
        set_partials_all(16'sd0);
        cut_after = '0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;

        // ============================================================
        // T1: Reset 後 subtree_sums 全 0,valid 應有預期模式
        // (但 cut_after=0 時 subtree_valid[15]=1,所以 valid 不是全 0)
        // 我們檢查的是 sum 都是 0(從 reset 出來)
        // ============================================================
        @(posedge clk); #0.1;
        if (subtree_sums[15] === 32'sd0) begin
            $display("[PASS] T1 reset: subtree_sums[15]=0");
        end else begin
            $display("[FAIL] T1 reset: subtree_sums[15]=%0d (expected 0)", subtree_sums[15]);
            fails = fails + 1;
        end

        // ============================================================
        // T2: Dense IP (cut_after=0), all-1 partials → subtree_sums[15]=16
        //     向後相容驗證:不切時跟舊版單 tree 行為一致
        // ============================================================
        @(negedge clk);
        set_partials_all(16'sd1);
        cut_after = '0;
        en = 1;
        wait_pipeline;
        check_subtree(15, 1'b1, 32'sd16, "T2 Dense IP all-1 (no cuts)");

        // ============================================================
        // T3: Dense IP, partials=[1..16] → subtree_sums[15] = 136
        // ============================================================
        @(negedge clk);
        set_partials_1_to_16;
        cut_after = '0;
        en = 1;
        wait_pipeline;
        check_subtree(15, 1'b1, 32'sd136, "T3 Dense IP 1..16");

        // ============================================================
        // T4: 1 cut at position 7 (cut between partials[7] and partials[8])
        //     all-1 partials
        //     → subtree[0..7] valid=1 at pos 7 with sum=8
        //     → subtree[8..15] valid=1 at pos 15 with sum=8
        // ============================================================
        @(negedge clk);
        set_partials_all(16'sd1);
        cut_after = 15'b000_0000_1000_0000;  // bit 7 = cut_after[7] = 1
        en = 1;
        wait_pipeline;
        check_subtree(7,  1'b1, 32'sd8, "T4 cut@7 first half (sum=8)");
        check_subtree(15, 1'b1, 32'sd8, "T4 cut@7 second half (sum=8)");

        // ============================================================
        // T5: Paper Fig 10 風格 — 3 個 sub-tree (sizes 1, 2, 1)
        //     cut_after[0]=1, cut_after[2]=1, cut_after[3]=1
        //     partials = [1, 2, 3, 4, 0, 0, ..., 0]
        //
        //     Expected:
        //       subtree_sums[0]  = 1   (just partials[0],  "C20")
        //       subtree_sums[2]  = 5   (partials[1]+[2],   "C21")
        //       subtree_sums[3]  = 4   (just partials[3],  "C31")
        //       subtree_sums[15] = 0   (partials[4..15] = 0)
        // ============================================================
        @(negedge clk);
        set_partials_fig10;
        cut_after = 15'b000_0000_0000_1101;  // bit 0, 2, 3 = cut
        en = 1;
        wait_pipeline;
        check_subtree(0,  1'b1, 32'sd1, "T5 Fig10 subtree[0] = 1 (C20)");
        check_subtree(2,  1'b1, 32'sd5, "T5 Fig10 subtree[2] = 5 (C21)");
        check_subtree(3,  1'b1, 32'sd4, "T5 Fig10 subtree[3] = 4 (C31)");
        check_subtree(15, 1'b1, 32'sd0, "T5 Fig10 subtree[15] = 0 (rest)");

        // ============================================================
        // T6: 全 cut (15'h7FFF) → 16 個獨立 sub-tree,每個 = partials[i]
        //     partials = [1..16]
        // ============================================================
        @(negedge clk);
        set_partials_1_to_16;
        cut_after = 15'h7FFF;  // 全 1,15 個 cut 全開
        en = 1;
        wait_pipeline;
        check_subtree(0,  1'b1, 32'sd1,  "T6 all-cut [0]=1");
        check_subtree(7,  1'b1, 32'sd8,  "T6 all-cut [7]=8");
        check_subtree(14, 1'b1, 32'sd15, "T6 all-cut [14]=15");
        check_subtree(15, 1'b1, 32'sd16, "T6 all-cut [15]=16");

        // ============================================================
        // T7: Sign handling — 負數 + 正負交替,no cuts
        //     partials = [+1, -1, +2, -2, ..., +8, -8]
        //     → subtree_sums[15] = 0 (各對相消)
        // ============================================================
        @(negedge clk);
        set_partials_alternating;
        cut_after = '0;
        en = 1;
        wait_pipeline;
        check_subtree(15, 1'b1, 32'sd0, "T7 signed alternating sum=0");

        // ============================================================
        // T8: 邊界值 — all INT16_MAX (32767),no cuts
        //     subtree_sums[15] = 16 × 32767 = 524272
        //     確保 INT32 不溢位
        // ============================================================
        @(negedge clk);
        set_partials_all(16'sd32767);
        cut_after = '0;
        en = 1;
        wait_pipeline;
        check_subtree(15, 1'b1, 32'sd524272, "T8 INT16_MAX*16 no overflow");

        // ============================================================
        // T9: 中段 1 cut + 邊界值 (cut at [7])
        //     all INT16_MAX
        //     → subtree[7] = 8 × 32767 = 262136
        //     → subtree[15] = 8 × 32767 = 262136
        // ============================================================
        @(negedge clk);
        set_partials_all(16'sd32767);
        cut_after = 15'b000_0000_1000_0000;
        en = 1;
        wait_pipeline;
        check_subtree(7,  1'b1, 32'sd262136, "T9 INT16_MAX*8 first half");
        check_subtree(15, 1'b1, 32'sd262136, "T9 INT16_MAX*8 second half");

        // ============================================================
        // 結束
        // ============================================================
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
        #100000;
        $display("[ERR] timeout");
        $finish;
    end

endmodule
