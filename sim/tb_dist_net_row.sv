// =============================================================================
// tb_dist_net_row.sv — dist_net_row 單元測試
// =============================================================================
// 測 module: rtl/dist/dist_net_row.sv
// Owner: NoC(黃妍心 + QuillQ)
//
// 跑法: make tb_dist_net
//
// === 測什麼 ===
//   T1: Dense IP identity idx → out = in(pass-through),延 DIST_STAGES 拍
//   T2: TrIP gather — idx 反轉 [15,14,...,0] → out[m] = in[15-m]
//   T3: TrIP gather — idx 壓縮 [3,1,0,...] → out[0]=in[3], out[1]=in[1], out[2]=in[0]
// =============================================================================

`timescale 1ns/1ps

module tb_dist_net_row;
    import trapezoid_pkg::*;

    logic                                  clk = 0;
    logic                                  rst_n;
    logic                                  en;
    logic                                  in_valid;
    logic [1:0]                            dataflow_sel;
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] a_vec_in;
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] b_vec_in;
    logic        [N_MUL_ROW-1:0][4:0]        effectual_idx;
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] a_vec_out;
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0] b_vec_out;
    logic                                    out_valid;

    int fails;
    integer i;

    always #1 clk = ~clk;

    dist_net_row dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .en            (en),
        .in_valid      (in_valid),
        .dataflow_sel  (dataflow_sel),
        .a_vec_in      (a_vec_in),
        .b_vec_in      (b_vec_in),
        .effectual_idx (effectual_idx),
        .a_vec_out     (a_vec_out),
        .b_vec_out     (b_vec_out),
        .out_valid     (out_valid)
    );

    // a = [0,1,...,15], b = [32,33,...,47]  (都 fit INT8,a/b 可區分)
    task set_inputs;
        for (i = 0; i < N_MUL_ROW; i = i + 1) begin
            a_vec_in[i] = i;
            b_vec_in[i] = i + 32;
        end
    endtask

    task set_idx_identity;
        for (i = 0; i < N_MUL_ROW; i = i + 1) effectual_idx[i] = i[4:0];
    endtask

    task set_idx_reverse;
        for (i = 0; i < N_MUL_ROW; i = i + 1) effectual_idx[i] = (N_MUL_ROW-1-i);
    endtask

    task wait_dist;
        repeat (DIST_STAGES) @(posedge clk);
        #0.1;
    endtask

    // 驗 out[m] == a_vec_in[exp_src[m]] (用 idx 推期望)
    task check_gather(input string msg);
        logic ok; integer src;
        ok = 1'b1;
        for (i = 0; i < N_MUL_ROW; i = i + 1) begin
            src = effectual_idx[i];
            if (a_vec_out[i] !== src) begin
                $display("[FAIL] %s: a_out[%0d]=%0d (expected in[%0d]=%0d)",
                         msg, i, a_vec_out[i], src, src); ok = 0;
            end
            if (b_vec_out[i] !== (src+32)) begin
                $display("[FAIL] %s: b_out[%0d]=%0d (expected in[%0d]=%0d)",
                         msg, i, b_vec_out[i], src, src+32); ok = 0;
            end
        end
        if (ok) $display("[PASS] %s: gather correct (16 lanes)", msg);
        else    fails = fails + 1;
    endtask

    initial begin
        $dumpfile("tb_dist_net_row.vcd");
        $dumpvars(0, tb_dist_net_row);
        fails = 0;

        rst_n = 0; en = 0; in_valid = 0;
        dataflow_sel = MODE_DENSE_IP;
        set_inputs; set_idx_identity;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1; en = 1;

        // T1: Dense identity → pass-through
        @(negedge clk);
        set_inputs; set_idx_identity; in_valid = 1; dataflow_sel = MODE_DENSE_IP;
        wait_dist;
        check_gather("T1 Dense identity pass-through");

        // T2: TrIP reverse gather
        @(negedge clk);
        set_inputs; set_idx_reverse; in_valid = 1; dataflow_sel = MODE_TRIP;
        wait_dist;
        check_gather("T2 TrIP reverse gather");

        // T3: TrIP 壓縮 gather — idx[0]=3, idx[1]=1, idx[2]=0, 其餘 0
        @(negedge clk);
        set_inputs;
        for (i = 0; i < N_MUL_ROW; i = i + 1) effectual_idx[i] = 5'd0;
        effectual_idx[0] = 5'd3;
        effectual_idx[1] = 5'd1;
        effectual_idx[2] = 5'd0;
        in_valid = 1; dataflow_sel = MODE_TRIP;
        wait_dist;
        check_gather("T3 TrIP compressed gather");

        @(negedge clk); in_valid = 0;
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
        #100000; $display("[ERR] timeout"); $finish;
    end

endmodule
