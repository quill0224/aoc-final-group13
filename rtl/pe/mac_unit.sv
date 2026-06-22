// =============================================================================
// mac_unit.sv — uint8 (A) × int8 (B) registered multiplier for PE row
// =============================================================================
// Function:
//   Computes the product of an UNSIGNED uint8 activation a and a SIGNED int8
//   weight b; result registered in signed INT16 product. Multiply only, no
//   accumulation: product is the partial product of a single A/B pair.
//
//   Operand signedness matches the GEMM test data (GEMM/outputs/): the im2col
//   activation A is uint8 [0,255] (e.g. 0xFF = +255, NOT -1); the weight B is
//   int8 two's-complement [-128,127]. The earlier signed8×signed8 version
//   mis-read A's high bytes (0xFF as -1) and could not match golden_psum.
//
//   Zero-point is NOT applied here: this stage emits the raw term a*b. The
//   golden psum is Σ_k (A − zp)*B, so the −zp*Σ_k B[k][n] correction is folded
//   downstream into the PPU bias' (bias'[n] = bias[n] − zp*Σ_k B[k][n]). For
//   zp=0 layers (e.g. layer_40) the accumulated c_out already matches
//   golden_psum directly; for zp=136 (layer_00) the correction lands at the PPU.
//
// Datapath position:
//   Upstream:   operand dispatch / distribution stage feeds paired A/B
//               operands; en comes from the upper valid pipeline and marks
//               the input valid this cycle. (A-path wires upstream are still
//               declared `signed` but carry unsigned uint8 bytes; that is OK
//               because distribution is pure routing — no sign extension or
//               arithmetic happens before this multiply.)
//   This stage: PE row multiply stage, 16 in parallel, producing 16 partial
//               products in the same cycle.
//   Downstream: reduction tree does grouped summation; local buffer handles
//               later accumulation and storage; output-valid alignment is
//               managed by the upper pipeline.
//
// Interface:
//   clk      : clock, rising-edge triggered
//   rst_n    : asynchronous reset, active-low; clears product to 0
//   en       : output register enable; en=1 writes a*b, en=0 holds
//   a        : unsigned [7:0], uint8 activation operand A (0..255)
//   b        : signed   [7:0], two's-complement int8 weight operand B
//   product  : signed [15:0], registered partial product
//
// Timing:
//   latency    : 1 cycle; product lags input_valid by 1 cycle
//   throughput : with en held 1, one new product per cycle; with en=0 product
//                holds the previous value, downstream uses the valid pipe to
//                determine if it is valid
//
// Numeric range:
//   uint8 [0,255] × int8 [-128,127] → product [-32640, +32385], which fits
//   entirely in signed INT16, so no truncation/saturation/overflow handling is
//   needed (PROD_W = 16 unchanged).
// =============================================================================

module mac_unit (
    input                       clk,
    input                       rst_n,
    input                       en,         // when set, write a*b into product this cycle
    input         [7:0]         a,          // uint8 activation A (unsigned, 0..255)
    input  signed [7:0]         b,          // int8 weight B (signed, two's complement)
    output logic signed [15:0]  product     // INT16 = (unsigned a) * (signed b), registered
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)    product <= 16'sd0;
        // Zero-extend a to a 9-bit SIGNED value (MSB=0 so it stays 0..255) so the
        // multiply is computed as signed (uint8 × int8); a plain `a*b` with one
        // unsigned operand would force an all-unsigned multiply and mis-handle b<0.
        else if (en)   product <= $signed({1'b0, a}) * b;
        // else: hold (downstream stage uses the valid pipe to determine validity)
    end

endmodule
