// =============================================================================
// tb_pe_array.sv — 16×16 PE array 端到端測試(Dense IP vs 手算 A×B)
// =============================================================================
// 測 module: rtl/pe/pe_array.sv(內含 16× pe_row_full)
// 跑法: make tb_pe_array
//
// 流程:A 駐留(a_grid)、B 一 column 一拍從 row 0 streaming(縱向鏈下傳)、
//       drain、再逐 column dump 出 C,比對 expected = Σ_k A[i][k]*B[k][n]。
//
// 測項(都 Dense IP、單 K-tile K=16):
//   T1: A=1, B=1            → C[i][n]=16(基本)
//   T2: A[i][k]=i+1, B=1    → C[i][n]=16(i+1)(驗每條 row 各算各的 + B 重用)
//   T3: A=1, B[k][n]=n+1    → C[i][n]=16(n+1)(驗 column 位址 cur_n + 錯拍)
// =============================================================================
`timescale 1ns/1ps

module tb_pe_array;
    import trapezoid_pkg::*;

    logic                                                  clk = 0;
    logic                                                  rst_n;
    logic [1:0]                                            dataflow_sel;
    logic                                                  in_valid;
    logic [LOCAL_BUF_AW-1:0]                               cur_n;
    logic                                                  first_pass;
    logic                                                  dump_en;
    logic [LOCAL_BUF_AW-1:0]                               dump_addr;
    logic signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0] a_grid;
    logic        [N_PE_ROW-1:0][N_MUL_ROW-1:0]             a_bm_grid;
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0]               b_vec_top;
    logic        [N_MUL_ROW-1:0]                           b_bm_top;
    logic [N_PE_ROW-1:0][ACC_W-1:0]                        c_out;
    logic                                                  c_valid;

    int fails;
    integer i, k, n;

    always #1 clk = ~clk;

    pe_array dut (
        .clk(clk), .rst_n(rst_n),
        .dataflow_sel(dataflow_sel), .in_valid(in_valid), .cur_n(cur_n),
        .first_pass(first_pass), .dump_en(dump_en), .dump_addr(dump_addr),
        .a_grid(a_grid), .a_bm_grid(a_bm_grid),
        .b_vec_top(b_vec_top), .b_bm_top(b_bm_top),
        .c_out(c_out), .c_valid(c_valid)
    );

    // golden 矩陣(tb 算)
    logic signed [DATA_W-1:0] A [N_PE_ROW][N_MUL_ROW];
    logic signed [DATA_W-1:0] B [N_MUL_ROW][N_PE_ROW];   // B[k][n]
    int exp_c [N_PE_ROW][N_PE_ROW];                       // exp_c[i][n]

    // 依 test 設 A/B + 算 expected
    task automatic set_mats(input int tid);
        for (i = 0; i < N_PE_ROW; i++)
            for (k = 0; k < N_MUL_ROW; k++) begin
                case (tid)
                    1: A[i][k] = 8'sd1;
                    2: A[i][k] = i + 1;
                    3: A[i][k] = 8'sd1;
                endcase
            end
        for (k = 0; k < N_MUL_ROW; k++)
            for (n = 0; n < N_PE_ROW; n++) begin
                case (tid)
                    1: B[k][n] = 8'sd1;
                    2: B[k][n] = 8'sd1;
                    3: B[k][n] = n + 1;
                endcase
            end
        for (i = 0; i < N_PE_ROW; i++)
            for (n = 0; n < N_PE_ROW; n++) begin
                exp_c[i][n] = 0;
                for (k = 0; k < N_MUL_ROW; k++)
                    exp_c[i][n] += A[i][k] * B[k][n];
            end
    endtask

    // 把 A 灌進 a_grid(駐留),bitmask 全 1
    //   先組一整列(單層 packed index),再 a_grid[i]=arow(單層 index)→ 避開
    //   iverilog 對 packed 陣列「兩層變數索引」寫入的限制
    task automatic load_A;
        logic signed [N_MUL_ROW-1:0][DATA_W-1:0] arow;
        logic        [N_MUL_ROW-1:0]             abm;
        for (i = 0; i < N_PE_ROW; i++) begin
            for (k = 0; k < N_MUL_ROW; k++) begin
                arow[k] = A[i][k];
                abm[k]  = 1'b1;
            end
            a_grid[i]    = arow;
            a_bm_grid[i] = abm;
        end
        for (k = 0; k < N_MUL_ROW; k++) b_bm_top[k] = 1'b1;
    endtask

    // 串 16 個 B column(每拍一個,first_pass=1 覆蓋)
    task automatic stream_B;
        for (n = 0; n < N_PE_ROW; n++) begin
            @(negedge clk);
            for (k = 0; k < N_MUL_ROW; k++) b_vec_top[k] = B[k][n];
            in_valid = 1'b1; cur_n = n[LOCAL_BUF_AW-1:0]; first_pass = 1'b1;
        end
        @(negedge clk); in_valid = 1'b0; first_pass = 1'b0;
    endtask

    // dump 一個 column(dump_en → +2 → c_out settle)
    task automatic dump_col(input int col);
        @(negedge clk); dump_en = 1'b1; dump_addr = col[LOCAL_BUF_AW-1:0];
        @(negedge clk); dump_en = 1'b0;
        @(negedge clk);   // +2
    endtask

    task automatic run_test(input int tid);
        set_mats(tid);
        load_A;
        stream_B;
        repeat (50) @(posedge clk);    // drain(B 鏈到 row15 + pipeline + RMW)
        for (n = 0; n < N_PE_ROW; n++) begin
            dump_col(n);
            for (i = 0; i < N_PE_ROW; i++) begin
                if (c_out[i] !== exp_c[i][n]) begin
                    $display("[FAIL] T%0d C[%0d][%0d]=%0d (exp %0d)",
                             tid, i, n, $signed(c_out[i]), exp_c[i][n]);
                    fails++;
                end
            end
        end
        $display("[done] T%0d checked", tid);
    endtask

    initial begin
        $dumpfile("tb_pe_array.vcd");
        $dumpvars(0, tb_pe_array);
        fails = 0;
        rst_n = 0; dataflow_sel = MODE_DENSE_IP;
        in_valid = 0; cur_n = 0; first_pass = 0; dump_en = 0; dump_addr = 0;
        a_grid = '0; a_bm_grid = '0; b_vec_top = '0; b_bm_top = '0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;

        run_test(1);
        run_test(2);
        run_test(3);

        $display("");
        if (fails == 0) begin
            $display("==============================");
            $display("ALL TESTS PASSED");
            $display("==============================");
        end else begin
            $display("==============================");
            $display("%0d CHECK(S) FAILED", fails);
            $display("==============================");
        end
        $finish;
    end

    initial begin #500000; $display("[ERR] timeout"); $finish; end

endmodule
