// =============================================================================
// tb_pe_row_tail.sv — standalone self-checking TB for pe_row_tail (Step B-3)
// =============================================================================
// 不接 mfiu/crossbar:直接餵「合成的 crossbar 輸出」(a_val/b_val/lane_col/
// lane_valid/in_valid),並由 TB 代打 controller(first_pass/cur_n_base/dump)。
// 內含行為參考模型 exp[]:對每個 group 把 (uint8 a × int8 b) 依 lane_col 分組累加,
// first_pass→覆寫、否則→RMW 累加(Option A:addr = cur_n_base + lane_col)。
// 最後逐欄 dump,比對 c_out == exp。純 iverilog 可跑(無 mfiu)。
//
// 覆蓋:多欄分段、無效尾 off 繼承(不可誤送 col0)、跨 K-tile 累加、負權重(int8)、
//      cur_n_base 位移到第 2 個 N-tile、first_pass 覆寫清掉舊值。
// =============================================================================
`timescale 1ns/1ps

module tb_pe_row_tail;
    import trapezoid_pkg::*;

    logic                    clk, rst_n;
    logic                    in_valid;
    logic [7:0]              a_val      [0:15];
    logic [7:0]              b_val      [0:15];
    logic [3:0]              lane_col   [0:15];
    logic                    lane_valid [0:15];
    logic                    first_pass;
    logic [LOCAL_BUF_AW-1:0] cur_n_base;
    logic                    dump_en;
    logic [LOCAL_BUF_AW-1:0] dump_addr;
    logic                    c_valid;
    logic signed [ACC_W-1:0] c_out;

    pe_row_tail dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid),
        .a_val(a_val), .b_val(b_val), .lane_col(lane_col), .lane_valid(lane_valid),
        .first_pass(first_pass), .cur_n_base(cur_n_base),
        .dump_en(dump_en), .dump_addr(dump_addr),
        .c_valid(c_valid), .c_out(c_out)
    );

    // clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // reference model (per output column, full 512-deep address space)
    logic signed [ACC_W-1:0] exp     [0:511];
    logic                    exp_tch [0:511];

    integer errors;

    // ---- helpers ----------------------------------------------------------
    task automatic clear_lanes;
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1) begin
                a_val[i] = 8'd0; b_val[i] = 8'd0; lane_col[i] = 4'd0; lane_valid[i] = 1'b0;
            end
        end
    endtask

    task automatic set_lane(input int idx, input [7:0] a, input [7:0] b, input [3:0] col);
        begin
            a_val[idx] = a; b_val[idx] = b; lane_col[idx] = col; lane_valid[idx] = 1'b1;
        end
    endtask

    // drive one group (1-cycle in_valid pulse) + update reference + drain
    task automatic send_group(input logic fp, input logic [LOCAL_BUF_AW-1:0] base);
        logic signed [ACC_W-1:0] gsum [0:15];
        logic                    gtch [0:15];
        integer i; logic [LOCAL_BUF_AW-1:0] addr;
        logic signed [8:0]       aa;    // uint8 zero-extended → signed 9-bit (always ≥0)
        logic signed [7:0]       bb;    // int8 weight (reinterpret bits as signed)
        logic signed [ACC_W-1:0] prod;
        begin
            // reference: sum (uint8 a)*(int8 b) per lane_col within this group.
            // 用「宣告為 signed 的中間變數」算乘法,避免 self-determined 運算式把
            // int8 當無號(這是上一版參考模型的 bug,不是 DUT)。
            for (i = 0; i < 16; i = i + 1) begin gsum[i] = '0; gtch[i] = 1'b0; end
            for (i = 0; i < 16; i = i + 1) begin
                if (lane_valid[i]) begin
                    aa = $signed({1'b0, a_val[i]});
                    bb = b_val[i];                 // [7:0] → signed [7:0]:0xFF=-1
                    prod = aa * bb;                // 兩個 signed 宣告變數 → signed 乘
                    gsum[lane_col[i]] += prod;
                    gtch[lane_col[i]]  = 1'b1;
                end
            end
            for (i = 0; i < 16; i = i + 1) begin
                if (gtch[i]) begin
                    addr = base + i[LOCAL_BUF_AW-1:0];
                    if (fp) exp[addr]  = gsum[i];
                    else    exp[addr] += gsum[i];
                    exp_tch[addr] = 1'b1;
                end
            end
            // drive
            @(negedge clk);
            first_pass = fp; cur_n_base = base; in_valid = 1'b1;
            @(negedge clk);
            in_valid = 1'b0;
            clear_lanes();
            repeat (6) @(negedge clk);   // drain: mac1 + tree1 + S8a + RMW2 + margin
        end
    endtask

    // read one column out via dump port (latency 2)
    task automatic dump_read(input logic [LOCAL_BUF_AW-1:0] addr,
                             output logic signed [ACC_W-1:0] val);
        integer guard;
        begin
            @(negedge clk); dump_en = 1'b1; dump_addr = addr;
            @(negedge clk); dump_en = 1'b0;
            // c_valid ~2 cycles後拉起且只高 1 拍;在 negedge 輪詢抓它
            guard = 0;
            while (c_valid !== 1'b1 && guard < 8) begin
                @(negedge clk); guard = guard + 1;
            end
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

    // ---- stimulus ---------------------------------------------------------
    integer i;
    initial begin
        errors = 0;
        for (i = 0; i < 512; i = i + 1) begin exp[i] = '0; exp_tch[i] = 1'b0; end
        in_valid = 0; first_pass = 0; cur_n_base = '0; dump_en = 0; dump_addr = '0;
        clear_lanes();
        rst_n = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        // === N-tile0 (base=0), K-tile0: first_pass=1 (覆寫) ===
        // group: col0 = lanes0,1 ; col1 = lanes2,3,4 ; col2 = lane5 ; lanes6-15 無效(tail)
        clear_lanes();
        set_lane(0, 8'd10, 8'd3,  4'd0); set_lane(1, 8'd20, 8'd2,  4'd0);     // col0: 10*3+20*2=70
        set_lane(2, 8'd5,  8'd4,  4'd1); set_lane(3, 8'd1,  8'd1,  4'd1);
        set_lane(4, 8'd2,  8'd2,  4'd1);                                       // col1: 20+1+4=25
        set_lane(5, 8'd255,8'sd127,4'd2);                                      // col2: 255*127=32385 (tail 繼承測試)
        send_group(1'b1, 9'd0);

        // group: col3 = lanes0,1 ; col4 = lane2 (含負權重 int8)
        clear_lanes();
        set_lane(0, 8'd8,  8'hFF, 4'd3); set_lane(1, 8'd4, 8'hFE, 4'd3);       // col3: 8*(-1)+4*(-2)=-16
        set_lane(2, 8'd100,8'd1,  4'd4);                                       // col4: 100
        send_group(1'b1, 9'd0);

        // === N-tile0 (base=0), K-tile1: first_pass=0 (累加同欄) ===
        clear_lanes();
        set_lane(0, 8'd1, 8'd1, 4'd0); set_lane(1, 8'd2, 8'd3, 4'd0);          // col0 += 1+6=7  → 77
        set_lane(2, 8'd9, 8'sd127, 4'd1);                                      // col1 += 1143 → 1168
        send_group(1'b0, 9'd0);

        clear_lanes();
        set_lane(0, 8'd3, 8'hFF, 4'd3);                                        // col3 += -3 → -19
        send_group(1'b0, 9'd0);

        // === N-tile1 (base=16), K-tile0: first_pass=1 ===
        clear_lanes();
        set_lane(0, 8'd7, 8'd7, 4'd0); set_lane(1, 8'd6, 8'd1, 4'd1);          // addr16=49, addr17=6
        send_group(1'b1, 9'd16);

        // === overwrite 測試:再對 base=16 first_pass=1 寫 col0(addr16)新值 ===
        clear_lanes();
        set_lane(0, 8'd2, 8'd2, 4'd0);                                         // addr16 應被覆寫成 4(不是 49+4)
        send_group(1'b1, 9'd16);

        // settle, then dump+compare everything touched
        repeat (4) @(negedge clk);
        check_all();

        if (errors == 0) $display("\n==== tb_pe_row_tail PASS ====\n");
        else             $display("\n==== tb_pe_row_tail FAIL: %0d error(s) ====\n", errors);
        $finish;
    end

    // safety timeout
    initial begin
        #100000;
        $display("[TIMEOUT] tb_pe_row_tail did not finish");
        $finish;
    end

endmodule
