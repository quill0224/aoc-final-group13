// =============================================================================
// local_buffer_row.sv — per-PE-row 輸出累加 buffer(4-bank,SRAM-based)
// =============================================================================
// 功能:
//   儲存一條 PE row(固定 m)所有 output column n 的 C 部分和,容量
//   512 column × INT32(4 bank × 128 × 32-bit)。每拍接受最多 4 筆
//   write request(sum + column 位址),依位址路由至對應 bank:
//     first_pass=1 → 覆蓋寫入(該 column 的第一段 K,等效清零,不發讀)
//     first_pass=0 → 累加(read-modify-write:讀舊值 + sum 寫回)
//   另提供 dump 介面讀出單一 column 的最終值(寫回 GLB 用)。
//
// 位址映射:
//   column 位址 addr[8:0] → bank = addr[1:0],bank 內 offset = addr[8:2]。
//   同一拍多筆 request 落在互異 bank 時並行寫入。
//
// 介面:
//   clk / rst_n / en         時脈;非同步 reset(active-low);pipeline 致能
//   wr_valid   [4]      in   各 lane 此拍是否有 request
//   wr_sum     [4][32]  in   各 lane 的部分和(signed)
//   wr_addr    [4][9]   in   各 lane 的 column 位址
//   first_pass          in   1 = 覆蓋寫入;0 = RMW 累加
//   acc_en              in   此拍 wr_* 有效(與上游資料 valid 同拍)
//   dump_en / dump_addr in   讀出請求 / column 位址
//   c_valid             out  dump 結果有效(dump_en 後第 2 拍)
//   c_out      [32]     out  dump 結果(signed)
//
// 時序:
//   累加 RMW = 2 拍 pipeline:T 拍發讀,T+1 拍「舊值 + sum」寫回;
//   每拍可接受新 request(fully pipelined)。
//   連續兩拍寫同一 column 時,SRAM 讀值尚未更新(讀延遲 1 拍)→
//   以 write-forward bypass 改用前一拍的寫回值,結果仍正確。
//   dump:dump_en 於 T 拍 → c_valid / c_out 於 T+2 拍有效。
//
// 假設與限制:
//   - 同一拍的有效 request 須落在互異 bank(wr_addr[1:0] 互異);
//     同 bank 衝突不序列化(模擬期 assertion 檢查)。上游 pe_row 負責
//     把 tree 的 16-lane 輸出壓縮為符合此條件的 ≤4 筆。
//   - dump_en 不可與 acc_en 同拍(共用讀埠)。
//   - ACC_W = 32,對齊 bank(128×32 SRAM)資料寬度。
//
// 資料路徑位置:
//   上游:pe_row 的 16→4 壓縮層送入 ≤4 筆 banked write request(wr_*),
//        acc_en 與 tree 輸出 valid 同拍;first_pass / dump_* 由 dataflow
//        控制邏輯(經 pe_row 延遲對齊)給入。
//   本級:pe_row_full 的 S8(輸出累加)。
//   下游:c_out → GLB 寫回路徑。
//   bank 為 sram_128x32_1r1w wrapper,合成時定義 USE_SRAM_MACRO 接真實 macro。
// =============================================================================

module local_buffer_row
    import trapezoid_pkg::*;
(
    input  logic                                            clk,
    input  logic                                            rst_n,
    input  logic                                            en,

    // ── 最多 4 筆 banked write request(上游已壓成 ≤4 筆、落不同 bank)──
    input  logic        [N_BANK_LBUF-1:0]                   wr_valid,
    input  logic signed [N_BANK_LBUF-1:0][ACC_W-1:0]        wr_sum,
    input  logic        [N_BANK_LBUF-1:0][LOCAL_BUF_AW-1:0] wr_addr,
    input  logic                                            first_pass, // 第一段 K:覆蓋
    input  logic                                            acc_en,

    // ── dump(不可與 acc_en 同拍)──
    input  logic                                            dump_en,
    input  logic        [LOCAL_BUF_AW-1:0]                  dump_addr,
    output logic                                            c_valid,
    output logic signed [ACC_W-1:0]                         c_out
);

    localparam int NB   = N_BANK_LBUF;        // 4
    localparam int OFFW = LOCAL_BUF_AW - 2;   // 7 (128 深/bank)

    // ── Layer 0:unpack 輸入 + 預先解碼 bank/offset(避開 iverilog 在 always 裡
    //    對變數索引元素再 bit-select 的限制;用 generate-assign 先拆好)──
    logic                    wv_u    [NB];
    logic signed [ACC_W-1:0] ws_u    [NB];
    logic [1:0]              wbank_u [NB];
    logic [OFFW-1:0]         woff_u  [NB];
    genvar gi;
    generate
        for (gi = 0; gi < NB; gi = gi + 1) begin : g_unpack
            assign wv_u[gi]    = wr_valid[gi];
            assign ws_u[gi]    = wr_sum[gi];
            assign wbank_u[gi] = wr_addr[gi][1:0];               // bank = addr[1:0]
            assign woff_u[gi]  = wr_addr[gi][LOCAL_BUF_AW-1:2];  // offset = addr[高位]
        end
    endgenerate

    // ── Layer 1+2:把每筆 request 依 bank 路由到對應 bank ──
    logic                    req_v   [NB];
    logic signed [ACC_W-1:0] req_sum [NB];
    logic [OFFW-1:0]         req_off [NB];
    genvar gb;
    generate
        for (gb = 0; gb < NB; gb = gb + 1) begin : g_route
            always_comb begin
                req_v[gb]   = 1'b0;
                req_sum[gb] = '0;
                req_off[gb] = '0;
                for (int k = 0; k < NB; k = k + 1) begin
                    if (wv_u[k] && (wbank_u[k] == gb[1:0])) begin
                        req_v[gb]   = 1'b1;
                        req_sum[gb] = ws_u[k];
                        req_off[gb] = woff_u[k];
                    end
                end
            end
        end
    endgenerate

    // dump 解碼
    logic [1:0]      dump_bank;
    logic [OFFW-1:0] dump_off;
    assign dump_bank = dump_addr[1:0];
    assign dump_off  = dump_addr[LOCAL_BUF_AW-1:2];

    // ── per-bank SRAM 介面線 ──
    logic            bk_ren   [NB];
    logic [OFFW-1:0] bk_raddr [NB];
    logic [31:0]     bk_rdata [NB];
    logic            bk_wen   [NB];
    logic [OFFW-1:0] bk_waddr [NB];
    logic [31:0]     bk_wdata [NB];

    // ── Stage-1 暫存器 ──
    logic                    s1_v    [NB];
    logic signed [ACC_W-1:0] s1_sum  [NB];
    logic [OFFW-1:0]         s1_off  [NB];
    logic                    s1_first;
    logic                    dump_pend;
    logic [1:0]              dump_bank_q;

    // RMW bypass:記住「上一拍每個 bank 寫了什麼」,給連續同地址累加用(classifier N=1)
    logic             prev_wen   [NB];
    logic [OFFW-1:0]  prev_waddr [NB];
    logic [ACC_W-1:0] prev_wdata [NB];

    // ── Stage 0:發 READ(acc 的 RMW 讀,或 dump 讀)──
    always_comb begin
        for (int b = 0; b < NB; b = b + 1) begin
            bk_ren[b]   = 1'b0;
            bk_raddr[b] = '0;
        end
        if (en && acc_en && !first_pass) begin
            // RMW:每個有 request 的 bank 先讀舊值
            for (int b = 0; b < NB; b = b + 1) begin
                if (req_v[b]) begin
                    bk_ren[b]   = 1'b1;
                    bk_raddr[b] = req_off[b];
                end
            end
        end else if (en && dump_en) begin
            bk_ren[dump_bank]   = 1'b1;
            bk_raddr[dump_bank] = dump_off;
        end
    end

    // ── 把 request / dump 打進 Stage 1 ──
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int b = 0; b < NB; b = b + 1) begin
                s1_v[b]       <= 1'b0;
                s1_sum[b]     <= '0;
                s1_off[b]     <= '0;
                prev_wen[b]   <= 1'b0;
                prev_waddr[b] <= '0;
                prev_wdata[b] <= '0;
            end
            s1_first    <= 1'b0;
            dump_pend   <= 1'b0;
            dump_bank_q <= '0;
            c_valid     <= 1'b0;
            c_out       <= '0;
        end else if (en) begin
            for (int b = 0; b < NB; b = b + 1) begin
                s1_v[b]       <= acc_en & req_v[b];
                s1_sum[b]     <= req_sum[b];
                s1_off[b]     <= req_off[b];
                prev_wen[b]   <= bk_wen[b];     // 記住這拍寫了什麼,給下一拍 bypass
                prev_waddr[b] <= bk_waddr[b];
                prev_wdata[b] <= bk_wdata[b];
            end
            s1_first    <= first_pass;
            dump_pend   <= dump_en;
            dump_bank_q <= dump_bank;
            // dump 輸出:read 延遲 1 拍 → 此處再 reg 一拍輸出
            c_valid <= dump_pend;
            c_out   <= $signed(bk_rdata[dump_bank_q]);
        end
    end

    // ── Stage 1:算 write data,驅動 bank 寫回(含 RMW bypass)──
    logic signed [ACC_W-1:0] rd_val [NB];
    always_comb begin
        for (int b = 0; b < NB; b = b + 1) begin
            // RMW bypass:若這拍要讀的 offset == 上一拍剛寫的 offset,SRAM 還沒更新
            // (讀延遲 1 拍)→ 直接用上一拍寫的值(classifier N=1 連續累加會踩到)
            if (prev_wen[b] && (s1_off[b] == prev_waddr[b]))
                rd_val[b] = $signed(prev_wdata[b]);
            else
                rd_val[b] = $signed(bk_rdata[b]);

            bk_wen[b]   = en & s1_v[b];
            bk_waddr[b] = s1_off[b];
            if (s1_first)
                bk_wdata[b] = s1_sum[b];               // 覆蓋(first_pass)
            else
                bk_wdata[b] = rd_val[b] + s1_sum[b];   // 累加(RMW,含 bypass)
        end
    end

    // ── 4 顆 SRAM bank ──
    generate
        for (gb = 0; gb < NB; gb = gb + 1) begin : g_bank
            sram_128x32_1r1w u_bank (
                .clk   (clk),
                .ren   (bk_ren[gb]),
                .raddr (bk_raddr[gb]),
                .rdata (bk_rdata[gb]),
                .wen   (bk_wen[gb]),
                .waddr (bk_waddr[gb]),
                .wdata (bk_wdata[gb])
            );
        end
    endgenerate

    // ── 設計假設檢查(合成略過)──
    // synthesis translate_off
    // 此 block 為 sim-only assertion;rst_n 在此僅作同步條件 gate(非真 reset),
    // 與其他 flop 的 async rst_n 並用會觸發 verilator SYNCASYNCNET,故局部關閉。
    /* verilator lint_off SYNCASYNCNET */
    always @(posedge clk) if (rst_n && en && acc_en) begin
        for (int ai = 0; ai < NB; ai = ai + 1)
            for (int aj = ai + 1; aj < NB; aj = aj + 1)
                if (wv_u[ai] && wv_u[aj] && (wbank_u[ai] == wbank_u[aj]))
                    $display("[ASSERT-FAIL] %0t: lane %0d,%0d 同拍落在同一 bank %0d",
                             $time, ai, aj, wbank_u[ai]);
        if (dump_en)
            $display("[ASSERT-FAIL] %0t: dump_en 不可與 acc_en 同拍", $time);
    end
    /* verilator lint_on SYNCASYNCNET */
    // synthesis translate_on

endmodule
