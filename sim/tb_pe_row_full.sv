// =============================================================================
// tb_pe_row_full.sv — 完整 PE Row 端到端測試(Dense IP vs 手算 dot product)
// =============================================================================
// 測 module: rtl/pe/pe_row_full.sv
//   內含: A-reg latch + MFIU + dist net + mul×16 + flexagon tree + local buffer
// Owner: 黃妍心
//
// 跑法: make tb_pe_row_full
//
// === 測什麼(Dense IP)===
//   T1: K=16 單 tile,a=1·b=1 → buffer[5] = 16
//   T2: K=32 雙 tile,(a=1·b=1)+(a=1·b=2) → buffer[6] = 16+32 = 48
//   T3: B vertical forwarding,b_vec_out = b_vec_in 延 1 cycle
//   T4: 變化值,a=[1..16]·b=1 → buffer[7] = 136
//   T5: 不同 column 獨立(承前,buffer[5]=16, buffer[6]=48, buffer[7]=136 都還在)
//
// === Pipeline latency ===
//   PE_ROW_STAGES = 8(latch1 + MFIU3 + dist1 + mul1 + tree1 + buf1)
//   input cycle → buffer 累加 posedge(+8);dump registered read +1
//   tb 用 generous drain wait(12 拍)再 dump,不卡 cycle-accurate
// =============================================================================

`timescale 1ns/1ps

module tb_pe_row_full;
    import trapezoid_pkg::*;

    logic                                    clk = 0;
    logic                                    rst_n;
    logic [1:0]                              dataflow_sel;
    logic                                    in_valid;
    logic [LOCAL_BUF_AW-1:0]                 cur_n;
    logic                                    buf_clear;
    logic                                    dump_en;
    logic [LOCAL_BUF_AW-1:0]                 dump_addr;
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] a_vec;
    logic        [N_MUL_ROW-1:0]             a_bitmask;
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] b_vec_in;
    logic        [N_MUL_ROW-1:0]             b_bitmask_in;
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] b_vec_out;
    logic        [N_MUL_ROW-1:0]             b_bitmask_out;
    logic                                    b_valid_out;
    logic                                    c_valid;
    logic signed [ACC_W-1:0]                 c_out;

    int fails;
    integer i;

    always #1 clk = ~clk;

    pe_row_full dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .dataflow_sel  (dataflow_sel),
        .in_valid      (in_valid),
        .cur_n         (cur_n),
        .buf_clear     (buf_clear),
        .dump_en       (dump_en),
        .dump_addr     (dump_addr),
        .a_vec         (a_vec),
        .a_bitmask     (a_bitmask),
        .b_vec_in      (b_vec_in),
        .b_bitmask_in  (b_bitmask_in),
        .b_vec_out     (b_vec_out),
        .b_bitmask_out (b_bitmask_out),
        .b_valid_out   (b_valid_out),
        .c_valid       (c_valid),
        .c_out         (c_out)
    );

    // ── helpers ──
    task set_a_all(input signed [DATA_W-1:0] v);
        for (i = 0; i < N_MUL_ROW; i = i + 1) a_vec[i] = v;
    endtask
    task set_b_all(input signed [DATA_W-1:0] v);
        for (i = 0; i < N_MUL_ROW; i = i + 1) b_vec_in[i] = v;
    endtask
    task set_a_ramp;  // a = [1,2,...,16]
        for (i = 0; i < N_MUL_ROW; i = i + 1) a_vec[i] = i + 1;
    endtask
    task set_bm_all1;
        for (i = 0; i < N_MUL_ROW; i = i + 1) begin
            a_bitmask[i] = 1'b1; b_bitmask_in[i] = 1'b1;
        end
    endtask

    // 等 pipeline drain
    task drain;
        repeat (12) @(posedge clk);
        #0.1;
    endtask

    // 讀某 column 比對
    task dump_col(input [LOCAL_BUF_AW-1:0] n,
                  input signed [ACC_W-1:0] exp,
                  input string msg);
        @(negedge clk); dump_en = 1; dump_addr = n;
        @(posedge clk); #0.1;
        if (c_valid !== 1'b1) begin
            $display("[FAIL] %s: c_valid=%b", msg, c_valid); fails = fails + 1;
        end else if (c_out !== exp) begin
            $display("[FAIL] %s: col %0d c_out=%0d (expected %0d)", msg, n, c_out, exp);
            fails = fails + 1;
        end else begin
            $display("[PASS] %s: col %0d c_out=%0d", msg, n, c_out);
        end
        @(negedge clk); dump_en = 0;
    endtask

    initial begin
        $dumpfile("tb_pe_row_full.vcd");
        $dumpvars(0, tb_pe_row_full);
        fails = 0;

        rst_n = 0;
        dataflow_sel = MODE_DENSE_IP;
        in_valid = 0; cur_n = 0; buf_clear = 0; dump_en = 0; dump_addr = 0;
        set_a_all(0); set_b_all(0); set_bm_all1;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;

        // 清整個 buffer(pipeline 空時)
        @(negedge clk); buf_clear = 1;
        @(posedge clk); #0.1;
        @(negedge clk); buf_clear = 0;

        // ── T1: K=16 單 tile,a=1·b=1 → col 5 = 16 ──
        set_a_all(8'sd1); set_b_all(8'sd1);
        @(negedge clk); in_valid = 1; cur_n = 9'd5;
        @(negedge clk); in_valid = 0;
        drain;
        dump_col(9'd5, 32'sd16, "T1 K=16 ones col5");

        // ── T2: K=32 雙 tile → col 6 = 16 + 32 = 48 ──
        @(negedge clk);
        set_a_all(8'sd1); set_b_all(8'sd1);
        in_valid = 1; cur_n = 9'd6;       // tile 0
        @(negedge clk);
        set_b_all(8'sd2);                 // tile 1: b=2
        in_valid = 1; cur_n = 9'd6;
        @(negedge clk); in_valid = 0;
        drain;
        dump_col(9'd6, 32'sd48, "T2 K=32 col6 (16+32)");

        // ── T3: B forwarding,b_vec_out = b_vec_in 延 1 cycle ──
        @(negedge clk);
        set_b_all(8'sd7); cur_n = 9'd100; in_valid = 1;  // col 100 不影響 5/6/7
        @(posedge clk); #0.1;
        if (b_vec_out[0] === 8'sd7 && b_vec_out[15] === 8'sd7 && b_valid_out === 1'b1)
            $display("[PASS] T3 B-forward: b_vec_out=7 (delayed 1 cyc), b_valid_out=1");
        else begin
            $display("[FAIL] T3 B-forward: b_vec_out[0]=%0d [15]=%0d valid=%b",
                     b_vec_out[0], b_vec_out[15], b_valid_out);
            fails = fails + 1;
        end
        @(negedge clk); in_valid = 0;
        drain;

        // ── T4: a=[1..16]·b=1 → col 7 = sum(1..16) = 136 ──
        set_a_ramp; set_b_all(8'sd1);
        @(negedge clk); in_valid = 1; cur_n = 9'd7;
        @(negedge clk); in_valid = 0;
        drain;
        dump_col(9'd7, 32'sd136, "T4 ramp col7 = 136");

        // ── T5: 各 column 獨立,前面結果都還在 ──
        dump_col(9'd5, 32'sd16,  "T5 col5 still 16");
        dump_col(9'd6, 32'sd48,  "T5 col6 still 48");
        dump_col(9'd7, 32'sd136, "T5 col7 still 136");

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
        #200000; $display("[ERR] timeout"); $finish;
    end

endmodule
