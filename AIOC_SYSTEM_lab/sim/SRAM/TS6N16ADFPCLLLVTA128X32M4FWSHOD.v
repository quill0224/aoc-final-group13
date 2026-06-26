// Behavioral model of TS6N16ADFPCLLLVTA128X32M4FWSHOD two-port (1R1W) SRAM macro
// No timing information included, unsynthesizable, for simulation use only.

module TS6N16ADFPCLLLVTA128X32M4FWSHOD (
    input [1:0] RCT,
    input [1:0] WCT,
    input [2:0] KP,
    input [6:0] AA,
    input [31:0] D,
    input [31:0] BWEB,
    input [6:0] AB,
    output reg [31:0] Q,
    input CLKW,
    input WEB,
    input CLKR,
    input REB,
    input SLP,
    input DSLP,
    input SD
);

    reg [31:0] MEMORY [0:127];

    // Write Port (CLKW)
    always @(posedge CLKW) begin
        if (~WEB) begin
            // BWEB is active-low bit-write enable
            MEMORY[AA] <= (D & ~BWEB) | (MEMORY[AA] & BWEB);
        end
    end

    // Read Port (CLKR)
    always @(posedge CLKR) begin
        if (~REB) begin
            Q <= MEMORY[AB];
        end
    end

endmodule
