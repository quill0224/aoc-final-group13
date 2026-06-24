// =============================================================================
// SRAM_rtl.sv — Behavioral model of TSMC N16ADFP single-port SRAM macro
// Spec : 128 Words x 64 Bits (1 KB)
// Macro: TS1N16ADFPCLLLVTA128X64M4SWSHOD
//
// Interface contract:
//   CEB=0 : chip selected; CEB=1 : outputs hold last value
//   WEB=0 : write (BWEB masks individual bits, active-low)
//   WEB=1 : read  (synchronous, 1-cycle latency)
//   CEB=0 && WEB=0 && WEB=1 simultaneously is illegal (asserted in sim)
// =============================================================================

module SRAM_rtl (
    // Power / test pins (tie to 0 in synthesis, ignored in simulation)
    input  logic        SLP,
    input  logic        DSLP,
    input  logic        SD,
    input  logic [1:0]  RCT,
    input  logic [1:0]  WTSEL,
    input  logic [2:0]  KP,
    output logic        PUDELAY,

    // Core control
    input  logic        CLK,   // rising-edge triggered
    input  logic        CEB,   // chip enable, active-low
    input  logic        WEB,   // write enable, active-low

    // Address and data
    input  logic [6:0]  A,     // word address (0~127)
    input  logic [63:0] D,     // write data
    input  logic [63:0] BWEB,  // bit-write mask, active-low (0=write this bit)
    output logic [63:0] Q      // read data (registered, 1-cycle latency)
);

    // =========================================================================
    // Memory Array
    // =========================================================================
    logic [63:0] mem [0:127];
    logic [63:0] q_reg;

    // Initialise to 0 in simulation so TB reads before writes get 0, not X
`ifdef SIMULATION
    integer init_i;
    initial begin
        for (init_i = 0; init_i < 128; init_i = init_i + 1)
            mem[init_i] = 64'd0;
        q_reg = 64'd0;
    end
`endif

    // =========================================================================
    // Synchronous Read / Write
    // =========================================================================
    integer bit_i;

    always_ff @(posedge CLK) begin
        if (~CEB) begin
            if (~WEB) begin
                // Write: apply BWEB mask bit-by-bit
                for (bit_i = 0; bit_i < 64; bit_i = bit_i + 1) begin
                    if (~BWEB[bit_i])
                        mem[A][bit_i] <= D[bit_i];
                end
            end else begin
                // Read: synchronous, result available next cycle
                q_reg <= mem[A];
            end
        end
        // CEB=1: chip deselected, q_reg holds last value (no update)
    end

    // =========================================================================
    // Output
    // =========================================================================
    assign Q        = q_reg;
    assign PUDELAY  = 1'b0;   // no power-up delay in RTL model

    // =========================================================================
    // Simulation Assertions
    // =========================================================================
`ifdef SIMULATION

    // Read-Write hazard: CEB=0 with both WEB=0 and WEB=1 is nonsensical
    // (WEB is a single bit; this guards against X-propagation on WEB)
    always_ff @(posedge CLK) begin
        if (~CEB) begin
            assert (!($isunknown(WEB)))
                else $error("[SRAM %0t] WEB is X while CEB=0; undefined behaviour",
                            $time);
            assert (!($isunknown(A)))
                else $error("[SRAM %0t] Address A is X while CEB=0",
                            $time);
        end
    end

    // Write with X data or X mask is likely a TB bug
    always_ff @(posedge CLK) begin
        if (~CEB && ~WEB) begin
            assert (!($isunknown(D)))
                else $warning("[SRAM %0t] Write data D contains X", $time);
            assert (!($isunknown(BWEB)))
                else $warning("[SRAM %0t] BWEB contains X during write", $time);
        end
    end

`endif // SIMULATION

endmodule
