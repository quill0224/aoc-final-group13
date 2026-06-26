// =============================================================================
// sram_128x32_1r1w.sv — 128 x 32-bit synchronous SRAM (1R1W) wrapper
// =============================================================================
// Function:
//   128-word x 32-bit synchronous SRAM with independent read and write ports
//   (1R1W); in the same cycle it can read one address and write another.
//   Presents a clean, implementation-agnostic interface to the layer above
//   (active-high, no power/test pins); this wrapper handles the low-level
//   connections.
//
// Interface:
//   clk            in   shared read/write clock (rising-edge triggered)
//   ren / raddr    in   read enable; read address [6:0]
//   rdata          out  read data [31:0]
//   wen / waddr    in   write enable; write address [6:0]
//   wdata          in   write data [31:0]
//
// Timing:
//   Write: written on the rising edge of the cycle where wen=1.
//   Read:  read latency = 1 (address at cycle T, rdata valid at T+1).
//   Same-cycle same-address read+write: behavioral version reads the old
//   value; macro version follows the cell datasheet, so the layer above must
//   not rely on this behavior (local_buffer_row avoids it via write-forward
//   bypass).
//
// Configuration (`USE_SRAM_MACRO`):
//   Defined   -> instantiate TS6N16ADFPCLLLVTA128X32M4FWSHOD (two-port macro).
//                active-low pins (WEB/REB) inverted; BWEB all 0 (write all
//                bits); margin/test/power pins (RCT/WCT/KP/SLP/DSLP/SD) tied 0;
//                PUDELAY is an output, left unconnected.
//   Undefined -> behavioral model (reg array) for iverilog / Verilator sim.
//   Both configurations have identical interface timing, so simulation and
//   synthesis share the same upper-level RTL.
//
// Datapath location:
//   Both upstream and downstream is local_buffer_row: serves as its storage
//   bank (4 per PE row), read/write requests driven by its RMW pipeline
//   (read at cycle T, write-back at T+1), rdata returns to its accumulate /
//   dump logic. Does not directly face other units of the PE row.
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
    // Synthesis: connect the real ADFP macro (1R1W two-port 128×32)
    //   Write port: AA=write addr / D=data / BWEB=per-bit write mask (active-low, 0=write) / WEB=write enable (active-low) / CLKW
    //   Read port:  AB=read addr / REB=read enable (active-low) / CLKR / Q=data out
    //   Test/power pins tied to normal-operation values; PUDELAY is an output, left unconnected
    // =========================================================================
    TS6N16ADFPCLLLVTA128X32M4FWSHOD u_macro (
        .AA      (waddr),        // write addr [6:0]
        .D       (wdata),        // write data [31:0]
        .BWEB    ({32{1'b0}}),   // write all bits (active-low → 0=write; if sim does not write, change to 32'hFFFFFFFF)
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
    // =========================================================================
    // Simulation: behavioral 1R1W (read latency = 1 cycle)
    // =========================================================================
    logic [31:0] mem [0:127];
    always_ff @(posedge clk) begin
        if (wen) mem[waddr] <= wdata;     // write port
        if (ren) rdata      <= mem[raddr]; // read port, data out next cycle
    end
`endif

endmodule
