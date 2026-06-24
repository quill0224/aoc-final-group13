// =============================================================================
// mac_unit.sv - registered uint8 x int8 multiplier
// =============================================================================
// Computes an unsigned activation times a signed two's-complement weight.
// The INT16 result is registered with one-cycle latency. This block performs
// multiplication only; zero-point correction and accumulation are handled
// elsewhere.
// =============================================================================

module mac_unit (
    input                       clk,
    input                       rst_n,
    input                       en,         // output register enable
    input         [7:0]         a,          // unsigned activation
    input  signed [7:0]         b,          // signed weight
    output logic signed [15:0]  product
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)    product <= 16'sd0;
        // Zero-extension preserves A as unsigned while allowing signed multiply.
        else if (en)   product <= $signed({1'b0, a}) * b;
    end

endmodule
