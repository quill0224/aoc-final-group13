// =============================================================================
// sram_128x32_1r1w.sv - 128 x 32-bit synchronous 1R1W SRAM
// =============================================================================
// Independent synchronous read and write ports with one-cycle read latency.
// Define USE_SRAM_MACRO to instantiate the ADFP SRAM macro; otherwise a
// behavioral array is used. The caller must not depend on same-address
// read/write behavior.
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
    // ADFP two-port SRAM macro.
    TS6N16ADFPCLLLVTA128X32M4FWSHOD u_macro (
        .AA      (waddr),        // write addr [6:0]
        .D       (wdata),        // write data [31:0]
        .BWEB    ({32{1'b0}}),   // active-low bit write mask: write all bits
        .WEB     (~wen),         // write enable, active-low
        .CLKW    (clk),
        .AB      (raddr),        // read addr [6:0]
        .REB     (~ren),         // read enable, active-low
        .CLKR    (clk),
        .RCT     (2'b00),
        .WCT     (2'b00),
        .KP      (3'b000),
        .SLP     (1'b0),
        .DSLP    (1'b0),
        .SD      (1'b0),
        .PUDELAY (  ),           // output, unused
        .Q       (rdata)         // read data out [31:0]
    );
`else
    // Behavioral model with one-cycle read latency.
    logic [31:0] mem [0:127];
    always_ff @(posedge clk) begin
        if (wen) mem[waddr] <= wdata;     // write port
        if (ren) rdata      <= mem[raddr]; // read port, data out next cycle
    end
`endif

endmodule
