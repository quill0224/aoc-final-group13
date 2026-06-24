// =============================================================================
// tb_pe_row.sv — standalone self-checking TB for pe_row
// =============================================================================
// 驗證一條 PE row 的完整計算鏈:pe_mfiu_seq(+mfiu) -> crossbar -> pe_row_tail。
// 這補上 tb_pe_row_tail 沒測到的 mfiu(交集)+ crossbar(取值)那段
// (tb_pe_row_tail 是直接餵合成的 crossbar 輸出)。
//
// 作法:用 dense 陣列描述 A fiber 與 16 條 B 欄,TB 內壓成 bitmask+壓縮 nz 餵 DUT,
// 同時用 dense 算 golden:psum[n] = Σ_k uint8(A[k]) * int8(B[n][k]),只在 A、B
// 都非零(交集)時累加;first_pass 覆寫、否則 RMW 累加;位址 = cur_n_base + n。
// 每個欄只有「至少一個交集」才會被寫(對齊 HW:無 effectual 就不產 segment)。
// 含 mfiu,需 verilator(iverilog 不支援其 packed-2D 變數索引)。
// =============================================================================
`timescale 1ns/1ps

module tb_pe_row;
    import trapezoid_pkg::*;

    logic                    clk, rst_n;
    logic                    mode, start, done;
    logic [N_MUL_ROW-1:0]    a_bm_row;
    logic [N_MUL_ROW-1:0]    b_bm [0:15];
    logic [15:0][7:0]        a_nz_row;
    logic [15:0][7:0]        b_nz [0:15];
    logic                    first_pass;
    logic [LOCAL_BUF_AW-1:0] cur_n_base;
    logic                    dump_en;
    logic [LOCAL_BUF_AW-1:0] dump_addr;
    logic                    c_valid;
    logic signed [ACC_W-1:0] c_out;

    pe_row dut (
        .clk(clk), .rst_n(rst_n),
        .mode(mode), .start(start), .done(done),
        .a_bm_row(a_bm_row), .b_bm(b_bm),
        .a_nz_row(a_nz_row), .b_nz(b_nz),
        .first_pass(first_pass), .cur_n_base(cur_n_base),
        .dump_en(dump_en), .dump_addr(dump_addr),
        .c_valid(c_valid), .c_out(c_out)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // dense 描述(TB 輸入端):A fiber + 16 條 B 欄,各 16 個 k 槽
    logic [7:0] a_dense [0:15];
    logic [7:0] b_dense [0:15][0:15];   // [col][k];int8 以位元樣式存(0xFF = -1)

    // 參考模型 + dump 結果
    logic signed [ACC_W-1:0] exp     [0:511];
    logic                    exp_tch [0:511];
    integer errors;

    task automatic clear_dense;
        integer c, k;
        begin
            for (k = 0; k < 16; k = k + 1) a_dense[k] = 8'd0;
            for (c = 0; c < 16; c = c + 1)
                for (k = 0; k < 16; k = k + 1) b_dense[c][k] = 8'd0;
        end
    endtask

    // 壓 dense -> bitmask+nz 餵 DUT,同時把 golden 寫進 exp
    task automatic send_tile(input logic fp, input logic [LOCAL_BUF_AW-1:0] base);
        integer c, k, ra, rb;
        logic signed [8:0]       av;
        logic signed [7:0]       bv;
        logic signed [ACC_W-1:0] sum;
        logic                    touched;
        begin
            // A fiber 壓縮
            a_bm_row = '0; a_nz_row = '0; ra = 0;
            for (k = 0; k < 16; k = k + 1) begin
                if (a_dense[k] != 8'd0) begin
                    a_bm_row[k]      = 1'b1;
                    a_nz_row[ra[3:0]] = a_dense[k];
                    ra = ra + 1;
                end
            end
            // 每條 B 欄壓縮 + golden(用宣告 signed 的中間變數,避免無號乘)
            for (c = 0; c < 16; c = c + 1) begin
                b_bm[c] = '0; b_nz[c] = '0; rb = 0;
                sum = '0; touched = 1'b0;
                for (k = 0; k < 16; k = k + 1) begin
                    if (b_dense[c][k] != 8'd0) begin
                        b_bm[c][k]       = 1'b1;
                        b_nz[c][rb[3:0]] = b_dense[c][k];
                        rb = rb + 1;
                    end
                    if ((a_dense[k] != 8'd0) && (b_dense[c][k] != 8'd0)) begin
                        touched = 1'b1;
                        av = $signed({1'b0, a_dense[k]});  // uint8
                        bv = b_dense[c][k];                // int8(位元重新解讀為 signed)
                        sum = sum + av * bv;
                    end
                end
                if (touched) begin
                    if (fp) exp[base + c[LOCAL_BUF_AW-1:0]]  = sum;
                    else    exp[base + c[LOCAL_BUF_AW-1:0]] += sum;
                    exp_tch[base + c[LOCAL_BUF_AW-1:0]] = 1'b1;
                end
            end
            // 驅動一拍 start
            @(negedge clk);
            mode = 1'b1; first_pass = fp; cur_n_base = base; start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            // 等 mfiu_seq done,再放 tail 排空(mac+tree+S8a+local_buffer RMW)
            wait_done();
        end
    endtask

    task automatic wait_done;
        integer g;
        begin
            g = 0;
            while ((done !== 1'b1) && (g < 300)) begin @(negedge clk); g = g + 1; end
            repeat (8) @(negedge clk);
        end
    endtask

    task automatic dump_read(input logic [LOCAL_BUF_AW-1:0] addr,
                             output logic signed [ACC_W-1:0] val);
        integer g;
        begin
            @(negedge clk); dump_en = 1'b1; dump_addr = addr;
            @(negedge clk); dump_en = 1'b0;
            g = 0;
            while ((c_valid !== 1'b1) && (g < 8)) begin @(negedge clk); g = g + 1; end
            val = c_out;
            if (c_valid !== 1'b1) $display("[WARN] c_valid never high for addr %0d", addr);
        end
    endtask

    task automatic check_all;
        integer a; logic signed [ACC_W-1:0] got;
        begin
            for (a = 0; a < 512; a = a + 1) begin
                if (exp_tch[a]) begin
                    dump_read(a[LOCAL_BUF_AW-1:0], got);
                    if (got !== exp[a]) begin
                        errors = errors + 1;
                        $display("[FAIL] addr %0d: got %0d, exp %0d", a, got, exp[a]);
                    end else begin
                        $display("[ OK ] addr %0d = %0d", a, got);
                    end
                end
            end
        end
    endtask

    integer i;
    initial begin
        errors = 0;
        for (i = 0; i < 512; i = i + 1) begin exp[i] = '0; exp_tch[i] = 1'b0; end
        mode = 1'b1; start = 1'b0; first_pass = 1'b0; cur_n_base = '0;
        dump_en = 1'b0; dump_addr = '0;
        clear_dense();
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // ---- Tile 1 (base=0, first_pass=1):多欄交集 + 無交集欄 + 負權重 + 第二群 ----
        clear_dense();
        a_dense[0] = 8'd10; a_dense[3] = 8'd20; a_dense[7] = 8'd5;        // A fiber
        b_dense[0][0] = 8'd2;  b_dense[0][3] = 8'd3;                       // col0: 10*2+20*3=80
        b_dense[1][7] = 8'd4;                                             // col1: 5*4=20
        b_dense[2][3] = 8'hFF;                                            // col2: 20*(-1)=-20
        b_dense[3][5] = 8'd9;                                             // col3: A@5 無 -> 不寫
        b_dense[8][0] = 8'd6;                                             // col8(第二群): 10*6=60
        send_tile(1'b1, 9'd0);

        // ---- Tile 2 (base=0, first_pass=0):同欄累加 ----
        clear_dense();
        a_dense[0] = 8'd10; a_dense[3] = 8'd20; a_dense[7] = 8'd5;
        b_dense[0][0] = 8'd1;                                             // col0 += 10 -> 90
        b_dense[2][3] = 8'd2;                                             // col2 += 40 -> 20
        send_tile(1'b0, 9'd0);

        // ---- Tile 3 (base=16, first_pass=1):cur_n_base 位移 ----
        clear_dense();
        a_dense[0] = 8'd7; b_dense[0][0] = 8'd7;                          // addr16 = 49
        send_tile(1'b1, 9'd16);

        // ---- Tile 4 (base=16, first_pass=1):覆寫 addr16(49 -> 4)----
        clear_dense();
        a_dense[0] = 8'd2; b_dense[0][0] = 8'd2;                          // addr16 = 4
        send_tile(1'b1, 9'd16);

        repeat (4) @(negedge clk);
        check_all();

        if (errors == 0) $display("\n==== tb_pe_row PASS ====\n");
        else             $display("\n==== tb_pe_row FAIL: %0d error(s) ====\n", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("[TIMEOUT] tb_pe_row did not finish");
        $finish;
    end

endmodule
