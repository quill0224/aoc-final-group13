`include "AXI/AXI_define.svh"
`include "ASIC.svh"

// =============================================================================
// GLB.sv — Global Buffer (16 KB)
// 由 16 顆 SRAM_rtl (128x64) 組成。
// 外部介面: 32-bit Data, 18-bit Address, 4-bit Write Strobe
// =============================================================================

module GLB (
    input  logic                      clk,
    input  logic                      rst,    // Active High Reset
    input  logic                      EN,     // Active High (來自 Controller 的致能)
    input  logic                      WEB,    // Active Low  (0=Write, 1=Read)
    input  logic [3:0]                WSTRB,  // Active High (4-bit Byte Enable, 1=Write)
    input  logic [`GLB_ADDR_BITS-1:0] A,      // 18-bit Byte Address
    input  logic [31:0]               DI,     // 32-bit Data In
    output logic [31:0]               DO      // 32-bit Data Out
);

    // =========================================================================
    // 1. 位址解碼 (Address Decoding)
    // 位址切割: 
    // A[17:14] : 保留
    // A[13:10] : Bank 選擇 (0~15)
    // A[9:3]   : Word 位址 (0~127, 對應 SRAM 的 A[6:0])
    // A[2]     : 32-bit Half-Word 選擇 (0=低 32-bit, 1=高 32-bit)
    // A[1:0]   : Byte Offset (忽略，由 WSTRB 處理)
    // =========================================================================
    logic [15:0] bank_ce_n; // Active-Low Chip Enable for 16 Banks

    always_comb begin
        bank_ce_n = 16'hFFFF; // 預設全部 Disable
        if (EN) begin
            bank_ce_n[A[13:10]] = 1'b0; // 啟用對應 Bank
        end
    end

    // =========================================================================
    // 2. 資料對齊與遮罩轉換 (Data Packing & BWEB Generation)
    // 將 32-bit 的 DI 廣播至 64-bit，並根據 A[2] 產生 64-bit 的 Active-Low BWEB
    // =========================================================================
    logic [63:0] sram_di;
    logic [63:0] sram_bweb; // 0=Write this bit

    // 廣播 32-bit 資料到 64-bit 的高低半部
    assign sram_di = {DI, DI};

    always_comb begin
        sram_bweb = 64'hFFFF_FFFF_FFFF_FFFF; // 預設全部不寫入

        if (EN && ~WEB) begin // 寫入模式
            if (A[2] == 1'b1) begin
                // 寫入 64-bit 的高半部 [63:32]
                sram_bweb[39:32] = WSTRB[0] ? 8'h00 : 8'hFF;
                sram_bweb[47:40] = WSTRB[1] ? 8'h00 : 8'hFF;
                sram_bweb[55:48] = WSTRB[2] ? 8'h00 : 8'hFF;
                sram_bweb[63:56] = WSTRB[3] ? 8'h00 : 8'hFF;
            end else begin
                // 寫入 64-bit 的低半部 [31:0]
                sram_bweb[7:0]   = WSTRB[0] ? 8'h00 : 8'hFF;
                sram_bweb[15:8]  = WSTRB[1] ? 8'h00 : 8'hFF;
                sram_bweb[23:16] = WSTRB[2] ? 8'h00 : 8'hFF;
                sram_bweb[31:24] = WSTRB[3] ? 8'h00 : 8'hFF;
            end
        end
    end

    // =========================================================================
    // 3. SRAM Macro 實例化 (16 Banks)
    // =========================================================================
    logic [63:0] bank_q [0:15]; // 16 個 Bank 的讀出資料

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : gen_sram
            SRAM_rtl u_sram (
                .SLP    (1'b0),
                .DSLP   (1'b0),
                .SD     (1'b0),
                .RCT    (2'b00),
                .WTSEL  (2'b00),
                .KP     (3'b000),
                .PUDELAY(),
                .CLK    (clk),
                .CEB    (bank_ce_n[i]), // 各自的 Active-Low CS
                .WEB    (WEB),          // 寫入致能
                .A      (A[9:3]),       // 128 words (7-bit address)
                .D      (sram_di),      // 64-bit 寫入資料
                .BWEB   (sram_bweb),    // 64-bit 位元遮罩
                .Q      (bank_q[i])     // 64-bit 讀出資料
            );
        end
    endgenerate

    // =========================================================================
    // 4. 讀取資料多工器 (Read Data Unpacking & MUX)
    // =========================================================================
    // SRAM 有 1-cycle latency，必須將讀取的 Bank 索引與 Half-Word 索引延遲一拍
    logic [3:0] read_bank_idx_q;
    logic       read_half_idx_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            read_bank_idx_q <= 4'd0;
            read_half_idx_q <= 1'b0;
        end else if (EN && WEB) begin
            read_bank_idx_q <= A[13:10];
            read_half_idx_q <= A[2];
        end
    end

    // 選擇對應 Bank 的 64-bit 資料
    logic [63:0] selected_q_64;
    assign selected_q_64 = bank_q[read_bank_idx_q];

    // 根據延遲一拍的 A[2] 擷取高/低 32-bit
    always_comb begin
        if (read_half_idx_q) begin
            DO = selected_q_64[63:32];
        end else begin
            DO = selected_q_64[31:0];
        end
    end

endmodule
