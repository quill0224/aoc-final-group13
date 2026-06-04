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
    // 合成用:接真實 macro。pin name 依工作站 port list 填:
    //   sed -n '17213,17255p' .../VERILOG/N16ADFP_SRAM_100a.v
    // 典型 1R1W macro 會有:CLK / 寫致能 / AW(寫址) / D(資料入) / BW(bit-write)
    //                      / 讀致能 / AR(讀址) / Q(資料出)
    // -------------------------------------------------------------------------
    // TS6N16ADFPCLLLVTA128X32M4FWSHOD u_macro (
    //     .CLK   (clk),
    //     .AW    (waddr),
    //     .D     (wdata),
    //     .BW    ({32{1'b1}}),   // 全 bit 寫
    //     .???   (wen),          // 寫致能(看實際 pin)
    //     .AR    (raddr),
    //     .Q     (rdata),
    //     .???   (ren)           // 讀致能(看實際 pin)
    //     // ... 其餘 test/sleep pin 依 datasheet 綁固定值
    // );
    // =========================================================================
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
