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

    // Flattened read arrays. Index mapping:
    //   bm_flat [idx*16 +: 16]
    //   nz_flat [(idx*16+nz_idx)*8 +: 8]
    //   len_flat[idx*5 +: 5]
    output logic [16*16-1:0]       a_bm_flat,
    output logic [16*16*8-1:0]     a_nz_flat,
    output logic [16*5-1:0]        a_len_flat,
    output logic [16*16-1:0]       b_bm_flat,
    output logic [16*16*8-1:0]     b_nz_flat,
    output logic [16*5-1:0]        b_len_flat
);

    logic [15:0]      a_bm  [0:15];
    logic [15:0][7:0] a_nz  [0:15];
    logic [4:0]       a_len [0:15];
    logic [15:0]      b_bm  [0:15];
    logic [15:0][7:0] b_nz  [0:15];
    logic [4:0]       b_len [0:15];

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

    genvar gi, gj;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : g_flat_fiber
            assign a_bm_flat[gi*16 +: 16] = a_bm[gi];
            assign b_bm_flat[gi*16 +: 16] = b_bm[gi];
            assign a_len_flat[gi*5 +: 5]  = a_len[gi];
            assign b_len_flat[gi*5 +: 5]  = b_len[gi];
            for (gj = 0; gj < 16; gj = gj + 1) begin : g_flat_nz
                assign a_nz_flat[(gi*16 + gj)*8 +: 8] = a_nz[gi][gj];
                assign b_nz_flat[(gi*16 + gj)*8 +: 8] = b_nz[gi][gj];
            end
        end
    endgenerate

endmodule
