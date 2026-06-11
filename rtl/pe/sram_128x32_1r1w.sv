// =============================================================================
// sram_128x32_1r1w.sv — 128 × 32-bit 同步 SRAM(1R1W)wrapper
// =============================================================================
// 功能:
//   128 字 × 32-bit 同步 SRAM,讀埠與寫埠各自獨立(1R1W),同一拍可
//   同時讀一個位址、寫另一個位址。對上層提供與實作無關的乾淨介面
//   (active-high、無電源/測試腳),底層接法由本 wrapper 統一處理。
//
// 介面:
//   clk            in   讀寫共用時脈(上緣觸發)
//   ren / raddr    in   讀致能;讀位址 [6:0]
//   rdata          out  讀資料 [31:0]
//   wen / waddr    in   寫致能;寫位址 [6:0]
//   wdata          in   寫資料 [31:0]
//
// 時序:
//   寫入:wen=1 之該拍時脈上緣寫入。
//   讀出:read latency = 1(T 拍給位址,T+1 拍 rdata 有效)。
//   同拍同位址讀+寫:behavioral 版讀回舊值;macro 版以元件規格為準,
//   上層不應依賴此行為(local_buffer_row 以 write-forward bypass 迴避)。
//
// 組態(`USE_SRAM_MACRO`):
//   有定義 → instantiate TS6N16ADFPCLLLVTA128X32M4FWSHOD(兩埠 macro)。
//            active-low 腳(WEB/REB)取反;BWEB 全 0(全位元寫);
//            margin / test / 電源腳(RCT/WCT/KP/SLP/DSLP/SD)綁 0;
//            PUDELAY 為 output,不接。
//   未定義 → behavioral 模型(reg 陣列),供 iverilog / Verilator 模擬。
//   兩種組態介面時序一致,模擬與合成共用同一份上層 RTL。
//
// 資料路徑位置:
//   上游/下游皆為 local_buffer_row:作為其儲存 bank(每條 PE row 4 顆),
//   讀寫請求由其 RMW pipeline 驅動(T 拍發讀、T+1 拍寫回),
//   rdata 回到其累加 / dump 邏輯。不直接面對 PE row 的其他單元。
// =============================================================================

module sram_128x32_1r1w (
    input  logic        clk,
    // read port
    input  logic        ren,
    input  logic [6:0]  raddr,
    output logic [31:0] rdata,
    // write port
    input  logic        wen,
    input  logic [6:0]  waddr,
    input  logic [31:0] wdata
);

`ifdef USE_SRAM_MACRO
    // =========================================================================
    // 合成用:接真實 ADFP macro(1R1W 兩埠 128×32)
    //   寫埠:AA=寫址 / D=資料 / BWEB=逐位元寫遮罩(active-low,0=寫) / WEB=寫致能(active-low) / CLKW
    //   讀埠:AB=讀址 / REB=讀致能(active-low) / CLKR / Q=資料出
    //   測試/電源腳綁正常運作值;PUDELAY 是 output 不接
    // =========================================================================
    TS6N16ADFPCLLLVTA128X32M4FWSHOD u_macro (
        .AA      (waddr),        // 寫址 [6:0]
        .D       (wdata),        // 寫資料 [31:0]
        .BWEB    ({32{1'b0}}),   // 全位元寫(active-low → 0=寫;若 sim 不寫入則改 32'hFFFFFFFF)
        .WEB     (~wen),         // 寫致能 active-low
        .CLKW    (clk),
        .AB      (raddr),        // 讀址 [6:0]
        .REB     (~ren),         // 讀致能 active-low
        .CLKR    (clk),
        .RCT     (2'b00),
        .WCT     (2'b00),
        .KP      (3'b000),
        .SLP     (1'b0),
        .DSLP    (1'b0),
        .SD      (1'b0),
        .PUDELAY (  ),           // output,不使用
        .Q       (rdata)         // 讀資料出 [31:0]
    );
`else
    // =========================================================================
    // 模擬用:behavioral 1R1W(read latency = 1 cycle)
    // =========================================================================
    logic [31:0] mem [0:127];
    always_ff @(posedge clk) begin
        if (wen) mem[waddr] <= wdata;     // write port
        if (ren) rdata      <= mem[raddr]; // read port,下一拍出
    end
`endif

endmodule
