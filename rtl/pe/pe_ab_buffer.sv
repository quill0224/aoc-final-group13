// =============================================================================
// pe_ab_buffer.sv - A/B tile buffer
// =============================================================================
// Stores 16 A fibers and 16 B fibers. Each entry contains a 16-bit occupancy
// mask, up to 16 compressed values, and the nonzero count. Bitmasks feed the
// MFIU; compressed values feed the crossbar.
//
// tile_ready pulses when B entry 15 is written. This relies on the input
// stream providing all A fibers followed by all B fibers in index order.
// =============================================================================

module pe_ab_buffer (
    input  logic              clk,
    input  logic              rst_n,

    // Fiber write port
    input  logic [15:0]       in_bitmask,
    input  logic [15:0][7:0]  in_nz,      // in_nz[0..in_len-1] are valid
    input  logic [4:0]        in_len,
    input  logic              in_side,    // 0=A, 1=B
    input  logic [3:0]        in_idx,     // 0..15
    input  logic              in_valid,

    output logic              tile_ready,

    // Read arrays
    output logic [15:0]       a_bm  [0:15],
    output logic [15:0][7:0]  a_nz  [0:15],
    output logic [4:0]        a_len [0:15],
    output logic [15:0]       b_bm  [0:15],
    output logic [15:0][7:0]  b_nz  [0:15],
    output logic [4:0]        b_len [0:15]
);

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 16; i = i + 1) begin
                a_bm[i] <= '0; a_nz[i] <= '0; a_len[i] <= '0;
                b_bm[i] <= '0; b_nz[i] <= '0; b_len[i] <= '0;
            end
        end else if (in_valid) begin
            if (!in_side) begin   // A
                a_bm[in_idx]  <= in_bitmask;
                a_nz[in_idx]  <= in_nz;
                a_len[in_idx] <= in_len;
            end else begin        // B
                b_bm[in_idx]  <= in_bitmask;
                b_nz[in_idx]  <= in_nz;
                b_len[in_idx] <= in_len;
            end
        end
    end

    // B entry 15 completes the ordered tile transfer.
    assign tile_ready = in_valid && in_side && (in_idx == 4'd15);

endmodule
