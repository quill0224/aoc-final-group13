// =============================================================================
// tb_local_buffer.sv — 4-bank banked-accumulator local buffer 測試
// =============================================================================
// 測 module: rtl/pe/local_buffer_row.sv(+ rtl/pe/sram_128x32_1r1w.sv)
// Owner: 黃妍心
//
// 跑法: make tb_lbuf
//
// === 驗什麼 ===
//   T1: first_pass 寫 4 個不同 bank(col 0/1/2/3)→ 覆蓋
//   T2: 非 first_pass 累加同 4 col → RMW(讀舊+加)→ dump 比對
//   T3: offset≠0 的 column(col 8 = bank0/off2)覆蓋→累加→dump
//   T4: 只有單一 lane valid(col 5 = bank1/off1)覆蓋→累加→dump
//
// === pipeline 時序 ===
//   RMW 2 拍:request@t → read@t → write@t+1 → mem 在 t+2 更新
//   ★同一 column 連續寫要間隔 ≥2 拍(穿插 dataflow 自然成立);tb 用 drain 拉開
//   dump:dump_en@t → c_valid/c_out 在 t+2
// =============================================================================
`timescale 1ns/1ps

module tb_local_buffer;
    import trapezoid_pkg::*;

    logic                                            clk = 0;
    logic                                            rst_n;
    logic                                            en;
    logic        [N_BANK_LBUF-1:0]                   wr_valid;
    logic signed [N_BANK_LBUF-1:0][ACC_W-1:0]        wr_sum;
    logic        [N_BANK_LBUF-1:0][LOCAL_BUF_AW-1:0] wr_addr;
    logic                                            first_pass;
    logic                                            acc_en;
    logic                                            dump_en;
    logic        [LOCAL_BUF_AW-1:0]                  dump_addr;
    logic                                            c_valid;
    logic signed [ACC_W-1:0]                         c_out;

    int fails;

    always #1 clk = ~clk;

    local_buffer_row dut (
        .clk(clk), .rst_n(rst_n), .en(en),
        .wr_valid(wr_valid), .wr_sum(wr_sum), .wr_addr(wr_addr),
        .first_pass(first_pass), .acc_en(acc_en),
        .dump_en(dump_en), .dump_addr(dump_addr),
        .c_valid(c_valid), .c_out(c_out)
    );

    // 發一筆「4-lane」accumulate/overwrite request
    task automatic do_acc(
        input bit fp, input [N_BANK_LBUF-1:0] vmask,
        input signed [ACC_W-1:0] s0, input signed [ACC_W-1:0] s1v,
        input signed [ACC_W-1:0] s2, input signed [ACC_W-1:0] s3,
        input [LOCAL_BUF_AW-1:0] a0, input [LOCAL_BUF_AW-1:0] a1,
        input [LOCAL_BUF_AW-1:0] a2, input [LOCAL_BUF_AW-1:0] a3
    );
        @(negedge clk);
        wr_valid = vmask;
        wr_sum[0]=s0; wr_sum[1]=s1v; wr_sum[2]=s2; wr_sum[3]=s3;
        wr_addr[0]=a0; wr_addr[1]=a1; wr_addr[2]=a2; wr_addr[3]=a3;
        first_pass = fp; acc_en = 1'b1;
        @(negedge clk);
        acc_en = 1'b0; wr_valid = '0; first_pass = 1'b0;
    endtask

    task automatic drain; repeat (3) @(negedge clk); endtask

    // 讀某 column 比對
    task automatic do_dump(input [LOCAL_BUF_AW-1:0] col,
                           input signed [ACC_W-1:0] exp, input string msg);
        @(negedge clk); dump_en = 1'b1; dump_addr = col;
        @(negedge clk); dump_en = 1'b0;
        @(negedge clk);   // t+2:c_valid/c_out 已 settle
        if (c_valid !== 1'b1) begin
            $display("[FAIL] %s: c_valid=%b", msg, c_valid); fails++;
        end else if (c_out !== exp) begin
            $display("[FAIL] %s: col %0d c_out=%0d (expected %0d)", msg, col, c_out, exp); fails++;
        end else begin
            $display("[PASS] %s: col %0d = %0d", msg, col, c_out);
        end
    endtask

    initial begin
        $dumpfile("tb_local_buffer.vcd");
        $dumpvars(0, tb_local_buffer);
        fails = 0;
        rst_n=0; en=1; wr_valid='0; wr_sum='0; wr_addr='0;
        first_pass=0; acc_en=0; dump_en=0; dump_addr=0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;

        // ── T1:first_pass 覆蓋 col 0/1/2/3(banks 0/1/2/3,off 0)──
        do_acc(1'b1, 4'b1111, 32'sd100, 32'sd200, 32'sd300, 32'sd400,
               9'd0, 9'd1, 9'd2, 9'd3);
        drain;
        // ── T2:累加同 4 col(+1/+2/+3/+4)→ 101/202/303/404 ──
        do_acc(1'b0, 4'b1111, 32'sd1, 32'sd2, 32'sd3, 32'sd4,
               9'd0, 9'd1, 9'd2, 9'd3);
        drain;
        do_dump(9'd0, 32'sd101, "T2 col0 (100+1)");
        do_dump(9'd1, 32'sd202, "T2 col1 (200+2)");
        do_dump(9'd2, 32'sd303, "T2 col2 (300+3)");
        do_dump(9'd3, 32'sd404, "T2 col3 (400+4)");

        // ── T3:offset≠0(col 8 = bank0/off2)50 → +5 → 55 ──
        do_acc(1'b1, 4'b0001, 32'sd50, 0,0,0, 9'd8, 0,0,0); drain;
        do_acc(1'b0, 4'b0001, 32'sd5,  0,0,0, 9'd8, 0,0,0); drain;
        do_dump(9'd8, 32'sd55, "T3 col8 off2 (50+5)");

        // ── T4:單一 lane(col 5 = bank1/off1)70 → +7 → 77 ──
        do_acc(1'b1, 4'b0010, 0, 32'sd70, 0,0, 0, 9'd5, 0,0); drain;
        do_acc(1'b0, 4'b0010, 0, 32'sd7,  0,0, 0, 9'd5, 0,0); drain;
        do_dump(9'd5, 32'sd77, "T4 col5 bank1 (70+7)");

        // ── 確認 col0~3 不受 T3/T4 影響 ──
        do_dump(9'd0, 32'sd101, "T5 col0 still 101");
        do_dump(9'd3, 32'sd404, "T5 col3 still 404");

        // ── T6:N=1 連續累加(測 RMW bypass)──
        //    對同一個 col 12,連續 4 拍不 drain:first_pass=10 → +5 → +3 → +2 = 20
        //    沒有 bypass 的話,讀到的會是慢半拍的舊值 → 算錯
        @(negedge clk);
        wr_valid = 4'b0001; wr_addr[0] = 9'd12; wr_sum[0] = 32'sd10;
        first_pass = 1'b1; acc_en = 1'b1;          // 覆蓋 = 10
        @(negedge clk); wr_sum[0] = 32'sd5; first_pass = 1'b0;  // +5(連續,不 drain)
        @(negedge clk); wr_sum[0] = 32'sd3;                     // +3
        @(negedge clk); wr_sum[0] = 32'sd2;                     // +2
        @(negedge clk); acc_en = 1'b0; wr_valid = '0;
        drain;
        do_dump(9'd12, 32'sd20, "T6 N=1 連續累加 10+5+3+2 (RMW bypass)");

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

    initial begin #100000; $display("[ERR] timeout"); $finish; end

endmodule
