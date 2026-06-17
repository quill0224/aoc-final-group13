// =============================================================================
// tb_mfiu_mf_chain.sv — 多 fiber 端到端串接測試
// =============================================================================
// 鏈路: bitmask -> mfiu_adapter_mf (楊 mfiu 核心,4×4 交集) -> dist_net_row_trip
//        (2D gather) -> 最終 a/b 值
// 跑法: make tb_mfiu_mf_chain
//
// 測資(2 個有效運算,落在不同輸出 (r,c),證明多 fiber):
//   a_bitmask: A-fiber0 的 k=3、A-fiber2 的 k=5 非零
//   b_bitmask: B-fiber0 的 k=3、B-fiber1 的 k=5 非零
//   交集(楊 mfiu 掃 r,c,k):
//     (r=0,c=0,k=3)  -> lane 0
//     (r=2,c=1,k=5)  -> lane 1
//   值 a_values[r][k]=r*16+k, b_values[c][k]=c*16+k:
//     lane0: a=a[0][3]=3,  b=b[0][3]=3
//     lane1: a=a[2][5]=37, b=b[1][5]=21
//     其餘 lane 無效 -> 0
// =============================================================================

`timescale 1ns/1ps

module tb_mfiu_mf_chain;
    import trapezoid_pkg::*;

    localparam int LANES = N_MUL_ROW;
    localparam int RW = $clog2(N_A_FIBER);
    localparam int CW = $clog2(N_B_FIBER);
    localparam int KW = $clog2(BITMASK_W);

    logic clk = 0, rst_n, en, in_valid;
    logic [N_A_FIBER*BITMASK_W-1:0] a_bitmask;
    logic [N_B_FIBER*BITMASK_W-1:0] b_bitmask;

    // adapter -> dist 之間的線
    logic [LANES-1:0]          mf_vld;
    logic [LANES-1:0][RW-1:0]  mf_row;
    logic [LANES-1:0][CW-1:0]  mf_col;
    logic [LANES-1:0][KW-1:0]  mf_k;
    logic [4:0]                mf_cnt;
    logic                      mf_ovf, mf_meta_vld;

    logic signed [N_A_FIBER-1:0][BITMASK_W-1:0][DATA_W-1:0] a_values;
    logic signed [N_B_FIBER-1:0][BITMASK_W-1:0][DATA_W-1:0] b_values;

    logic signed [LANES-1:0][DATA_W-1:0] a_lane_out, b_lane_out;
    logic [LANES-1:0]          lane_valid_out;
    logic                      dist_vld;

    int fails = 0, l, waitc;

    always #1 clk = ~clk;

    // a_values[r][k]=r*16+k, b_values[c][k]=c*16+k
    genvar gr, gk;
    generate
        for (gr = 0; gr < N_A_FIBER; gr = gr + 1)
            for (gk = 0; gk < BITMASK_W; gk = gk + 1)
                assign a_values[gr][gk] = gr*BITMASK_W + gk;
        for (gr = 0; gr < N_B_FIBER; gr = gr + 1)
            for (gk = 0; gk < BITMASK_W; gk = gk + 1)
                assign b_values[gr][gk] = gr*BITMASK_W + gk;
    endgenerate

    mfiu_adapter_mf u_mf (
        .clk(clk), .rst_n(rst_n), .en(en), .in_valid(in_valid),
        .a_bitmask(a_bitmask), .b_bitmask(b_bitmask),
        .lane_valid(mf_vld), .a_row_sel(mf_row), .b_col_sel(mf_col), .k_sel(mf_k),
        .match_count(mf_cnt), .overflow(mf_ovf), .meta_valid(mf_meta_vld)
    );

    dist_net_row_trip u_dist (
        .clk(clk), .rst_n(rst_n), .en(en), .in_valid(mf_meta_vld),
        .a_values(a_values), .b_values(b_values),
        .lane_valid(mf_vld), .a_row_sel(mf_row), .b_col_sel(mf_col), .k_sel(mf_k),
        .a_lane_out(a_lane_out), .b_lane_out(b_lane_out),
        .lane_valid_out(lane_valid_out), .out_valid(dist_vld)
    );

    initial begin
        en = 1; in_valid = 0; rst_n = 0; a_bitmask = '0; b_bitmask = '0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // 設兩個有效交集
        a_bitmask = '0; a_bitmask[0*BITMASK_W + 3] = 1'b1; a_bitmask[2*BITMASK_W + 5] = 1'b1;
        b_bitmask = '0; b_bitmask[0*BITMASK_W + 3] = 1'b1; b_bitmask[1*BITMASK_W + 5] = 1'b1;

        @(negedge clk); in_valid = 1;
        @(negedge clk); in_valid = 0;

        // 等串接輸出 valid (MFIU_STAGES + DIST_STAGES 拍)
        waitc = 0;
        while (dist_vld !== 1'b1 && waitc < 20) begin @(negedge clk); waitc = waitc + 1; end

        $display("== mfiu_adapter_mf -> dist_net_row_trip 端到端 ==");
        $display("match_count=%0d overflow=%0b  (expect 2, 0)", mf_cnt, mf_ovf);

        if (a_lane_out[0] !== 8'sd3 || b_lane_out[0] !== 8'sd3) begin
            $display("[FAIL] lane0 a=%0d b=%0d (exp 3,3)", a_lane_out[0], b_lane_out[0]); fails = fails + 1;
        end
        if (a_lane_out[1] !== 8'sd37 || b_lane_out[1] !== 8'sd21) begin
            $display("[FAIL] lane1 a=%0d b=%0d (exp 37,21)", a_lane_out[1], b_lane_out[1]); fails = fails + 1;
        end
        for (l = 2; l < LANES; l = l + 1)
            if (lane_valid_out[l] !== 1'b0 || a_lane_out[l] !== 8'sd0) begin
                $display("[FAIL] lane%0d 應無效/0", l); fails = fails + 1;
            end
        if (mf_cnt !== 5'd2) begin $display("[FAIL] match_count=%0d exp 2", mf_cnt); fails = fails + 1; end

        if (fails == 0) $display("ALL PASS  (端到端: bitmask -> MFIU 交集 -> 2D gather 值正確)");
        else            $display("FAILED: %0d 個錯", fails);
        $finish;
    end

endmodule
