// =============================================================================
// tb_dist_net_row_trip.sv — dist_net_row_trip 單元測試
// =============================================================================
// 測 module: rtl/dist/dist_net_row_trip.sv (TrIP multi-fiber 2D gather)
// Owner: NoC(QuillQ + 黃妍心)   ·   跑法: make tb_dist_net_trip
//
// === 測什麼 ===
//   設 a_values[r][k] = r*16+k、b_values[c][k] = c*16+k (值 = flat slot index,好驗)
//   T1: 一般 gather   — lane 拿到 a=row*16+k, b=col*16+k
//   T2: invalid lane  — 吐 0,lane_valid_out=0
//   T3: 廣播 broadcast — 兩條 lane 指同一 (row,k) → 拿到同一值 (Benes 做不到)
//   T4: registered    — 輸出延 DIST_STAGES(=1) 拍、out_valid 跟著 in_valid
// =============================================================================

`timescale 1ns/1ps

module tb_dist_net_row_trip;
    import trapezoid_pkg::*;

    localparam int LANES     = N_MUL_ROW;     // 16
    localparam int RW        = $clog2(N_A_FIBER);  // 2
    localparam int CW        = $clog2(N_B_FIBER);  // 2
    localparam int KW        = $clog2(BITMASK_W);  // 4

    logic clk = 0, rst_n, en, in_valid;
    logic signed [N_A_FIBER-1:0][BITMASK_W-1:0][DATA_W-1:0] a_values;
    logic signed [N_B_FIBER-1:0][BITMASK_W-1:0][DATA_W-1:0] b_values;
    logic [LANES-1:0]            lane_valid;
    logic [LANES-1:0][RW-1:0]    a_row_sel;
    logic [LANES-1:0][CW-1:0]    b_col_sel;
    logic [LANES-1:0][KW-1:0]    k_sel;
    logic signed [LANES-1:0][DATA_W-1:0] a_lane_out;
    logic signed [LANES-1:0][DATA_W-1:0] b_lane_out;
    logic [LANES-1:0]            lane_valid_out;
    logic                        out_valid;

    int fails = 0;
    integer i, rr, kk, l;
    logic signed [DATA_W-1:0] ea, eb;   // 期望值暫存 (iverilog 不支援 task 內 automatic)

    // shadow 期望值用的 per-lane 設定
    logic [RW-1:0] exp_row [LANES];
    logic [CW-1:0] exp_col [LANES];
    logic [KW-1:0] exp_k   [LANES];
    logic          exp_vld [LANES];

    always #1 clk = ~clk;

    // a_values[r][k] = r*16+k, b_values[c][k] = c*16+k  (都 ≤63,fit INT8)
    // 用 generate constant assign 驅動 (iverilog 不接受 task 內雙重可變 index)
    genvar gvr, gvk;
    generate
        for (gvr = 0; gvr < N_A_FIBER; gvr = gvr + 1) begin : g_av
            for (gvk = 0; gvk < BITMASK_W; gvk = gvk + 1) begin : g_avk
                assign a_values[gvr][gvk] = gvr*BITMASK_W + gvk;
            end
        end
        for (gvr = 0; gvr < N_B_FIBER; gvr = gvr + 1) begin : g_bv
            for (gvk = 0; gvk < BITMASK_W; gvk = gvk + 1) begin : g_bvk
                assign b_values[gvr][gvk] = gvr*BITMASK_W + gvk;
            end
        end
    endgenerate

    dist_net_row_trip dut (
        .clk(clk), .rst_n(rst_n), .en(en), .in_valid(in_valid),
        .a_values(a_values), .b_values(b_values),
        .lane_valid(lane_valid), .a_row_sel(a_row_sel),
        .b_col_sel(b_col_sel), .k_sel(k_sel),
        .a_lane_out(a_lane_out), .b_lane_out(b_lane_out),
        .lane_valid_out(lane_valid_out), .out_valid(out_valid)
    );

    // 把 per-lane 設定推進 DUT 的 sel ports
    task drive_meta;
        for (l = 0; l < LANES; l = l + 1) begin
            a_row_sel[l]  = exp_row[l];
            b_col_sel[l]  = exp_col[l];
            k_sel[l]      = exp_k[l];
            lane_valid[l] = exp_vld[l];
        end
    endtask

    // 驅動一拍 valid,等 registered 輸出 (DIST_STAGES=1)
    task pulse_and_check;
        @(negedge clk); in_valid = 1; drive_meta();
        @(negedge clk); in_valid = 0;          // 此 negedge 後輸出已 register 好
        // 檢查
        if (out_valid !== 1'b1) begin
            $display("  [FAIL] out_valid 應為 1"); fails = fails + 1;
        end
        for (l = 0; l < LANES; l = l + 1) begin
            ea = exp_vld[l] ? (exp_row[l]*BITMASK_W + exp_k[l]) : '0;
            eb = exp_vld[l] ? (exp_col[l]*BITMASK_W + exp_k[l]) : '0;
            if (a_lane_out[l] !== ea) begin
                $display("  [FAIL] lane%0d a=%0d exp %0d", l, a_lane_out[l], ea);
                fails = fails + 1;
            end
            if (b_lane_out[l] !== eb) begin
                $display("  [FAIL] lane%0d b=%0d exp %0d", l, b_lane_out[l], eb);
                fails = fails + 1;
            end
            if (lane_valid_out[l] !== exp_vld[l]) begin
                $display("  [FAIL] lane%0d valid=%0b exp %0b", l, lane_valid_out[l], exp_vld[l]);
                fails = fails + 1;
            end
        end
    endtask

    initial begin
        en = 1; in_valid = 0; rst_n = 0;
        // default: 每條 lane 一個 deterministic 映射
        for (l = 0; l < LANES; l = l + 1) begin
            exp_row[l] = l % N_A_FIBER;
            exp_col[l] = (l + 1) % N_B_FIBER;
            exp_k[l]   = l % BITMASK_W;
            exp_vld[l] = 1'b1;
        end
        // T1 已含在 default;再塞 T2/T3 特例:
        exp_vld[2]  = 1'b0;                                   // T2: invalid lane
        exp_row[3]  = exp_row[0]; exp_col[3] = exp_col[0];    // T3: lane3 = lane0
        exp_k[3]    = exp_k[0];                               //     → 廣播,同值

        repeat (3) @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        $display("== dist_net_row_trip TB ==");
        $display("-- Scenario 1: gather / invalid lane / broadcast / registered --");
        pulse_and_check();

        // ====================================================================
        // Scenario 2: 多 fiber packing demo —— 4 個輸出塞滿 16 lane (一拍)
        //   (0,0): k={2,5,9}      → lane 0~2
        //   (0,1): k={0,3,7,11,14}→ lane 3~7
        //   (1,0): k={1,6,8}      → lane 8~10
        //   (1,1): k={4,10,12,13,15} → lane 11~15
        //   合計 3+5+3+5 = 16,利用率 100%。每 lane 各自 (row,col,k) 不同。
        // ====================================================================
        for (l = 0; l < LANES; l = l + 1) exp_vld[l] = 1'b1;
        // (0,0)
        exp_row[0]=0; exp_col[0]=0; exp_k[0]=2;
        exp_row[1]=0; exp_col[1]=0; exp_k[1]=5;
        exp_row[2]=0; exp_col[2]=0; exp_k[2]=9;
        // (0,1)
        exp_row[3]=0; exp_col[3]=1; exp_k[3]=0;
        exp_row[4]=0; exp_col[4]=1; exp_k[4]=3;
        exp_row[5]=0; exp_col[5]=1; exp_k[5]=7;
        exp_row[6]=0; exp_col[6]=1; exp_k[6]=11;
        exp_row[7]=0; exp_col[7]=1; exp_k[7]=14;
        // (1,0)
        exp_row[8]=1;  exp_col[8]=0;  exp_k[8]=1;
        exp_row[9]=1;  exp_col[9]=0;  exp_k[9]=6;
        exp_row[10]=1; exp_col[10]=0; exp_k[10]=8;
        // (1,1)
        exp_row[11]=1; exp_col[11]=1; exp_k[11]=4;
        exp_row[12]=1; exp_col[12]=1; exp_k[12]=10;
        exp_row[13]=1; exp_col[13]=1; exp_k[13]=12;
        exp_row[14]=1; exp_col[14]=1; exp_k[14]=13;
        exp_row[15]=1; exp_col[15]=1; exp_k[15]=15;

        $display("-- Scenario 2: 多 fiber packing (4 個輸出塞滿 16 lane, 100%% 利用率) --");
        pulse_and_check();

        if (fails == 0) $display("ALL PASS  (Scenario 1 + 多 fiber packing 都正確)");
        else            $display("FAILED: %0d 個錯", fails);
        $finish;
    end

endmodule
