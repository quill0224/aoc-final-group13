// =============================================================================
// local_buffer_row.sv — Per-PE-row 輸出累加 buffer(4-bank SRAM-macro 版)
// =============================================================================
// Owner: 黃妍心 | Paper: Trapezoid ISCA'24 §III.B banked local buffer
//
// === 關鍵設計 ===
//
// [用途] 每條 PE row 一個。存「這一列 m 的所有 output column n 的部分和」,
//        跨 K-tile pass 累加;整列算完後 dump 寫回 GLB。
//
// [為何要存全部 column] dataflow = A stationary + B streaming + tree 對 K reduce:
//        每拍 B 流進不同 column → 算不同 C[m][n] 的部分和;掃完一輪所有 column
//        後才換下一段 K、再掃一遍、累加回同一個 column。
//        → 必須同時存住所有 column 的部分和 → 深度 = 512 (= max N)。
//
// [存取型態:穿插] 同一個 column 隔「一整輪 B」(~N 拍)才再被寫一次,遠大於
//        SRAM 讀寫延遲 → 不會發生 same-address RMW hazard → RMW = 乾淨 2 拍 pipeline。
//        ★隱含假設:上游不會「連續兩拍寫同一個 column」(穿插 dataflow 自然成立)。
//
// [介面] 吃「最多 4 筆 banked write request」(不是 16-lane tree 原始輸出)。
//        上游 pe_row 負責把 16-lane tree 壓成 ≤4 筆;此處只做 4-bank RMW + dump。
//
// [Banking] N_BANK_LBUF=4 banks,每 bank 128 深 × 32-bit(= sram_128x32_1r1w)。
//        column c → bank = c[1:0],bank 內 offset = c[高位]。
//
// [初始化:first_pass 取代 bulk clear] SRAM 無法一拍清零:
//        first_pass=1(第一段 K)→ 直接「寫入」sum(覆蓋舊值=等效清零,不讀)
//        first_pass=0(後續 K) → RMW「累加」(讀舊 + 加 + 寫回)
//
// [RMW 2 拍 pipeline] cycle t  : 發 read 位址(該 bank 的 offset)
//                     cycle t+1: 舊值回來 → 加 sum(或覆蓋)→ 寫回
//
// [dump] dump_en/dump_addr:讀某 column 最終值 → c_out(2 拍後 c_valid)。
//        ★限制:dump_en 不可與 acc_en 同拍(共用 read port)。
//
// [v1 假設 / future work] 同一拍 ≤4 筆且落在「不同」bank(addr[1:0] 互異);
//        同 bank 衝突的序列化留待 future work(下方有 assertion 抓違規)。
//
// 註:此版假設 ACC_W = 32(對齊 128×32 macro 寬度)。
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
