// =============================================================================
// sram_128x32_1r1w.sv — 1R1W 128×32 SRAM wrapper
// =============================================================================
// 包一層乾淨介面,讓 local_buffer_row 不用綁死醜醜的 macro pin name。
//   合成:define USE_SRAM_MACRO → 接真實 ADFP macro
//         TS6N16ADFPCLLLVTA128X32M4FWSHOD(two-port 1R1W 128×32)
//   模擬:behavioral 1R1W 模型(iverilog 可跑,read 延遲 1 拍)
//
// 介面(1 read port + 1 write port,可同拍各做一件事):
//   read : ren / raddr → rdata(下一拍出)
//   write: wen / waddr / wdata(本拍寫入)
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
