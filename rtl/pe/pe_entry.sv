// =============================================================================
// pe_entry.sv - compressed-fiber stream receiver
// =============================================================================
// Receives one configuration beat followed by ceil(len/4) data beats and
// rebuilds a compressed fiber. pe_cfg_length[15] selects A or B and [4:0]
// gives the number of nonzero bytes. Data bytes arrive least-significant byte
// first. out_valid pulses for one cycle when the fiber is complete.
//
// The downstream buffer has no ready signal and is expected to accept every
// out_valid pulse. Fiber indices restart when the A/B side changes.
// =============================================================================

module pe_entry (
    input  logic        clk,
    input  logic        rst_n,

    // Input stream
    input  logic        pe_cfg_valid,
    output logic        pe_cfg_ready,
    input  logic [15:0] pe_cfg_length,    // [15]=is_b(0=A/1=B), [4:0]=len(0..16)
    input  logic [15:0] pe_cfg_bitmask,
    input  logic        pe_data_valid,
    output logic        pe_data_ready,
    input  logic [31:0] pe_data_nzvalue,  // four nonzero bytes, LSB first

    // Reconstructed fiber
    output logic [15:0]      out_bitmask,
    output logic [15:0][7:0] out_nz,       // out_nz[0..out_len-1] are valid
    output logic [4:0]       out_len,       // 0..16
    output logic             out_side,      // 0=A, 1=B
    output logic [3:0]       out_idx,       // index within the current A/B phase
    output logic             out_valid
);

    // Receive state
    typedef enum logic [1:0] { S_CFG, S_DATA, S_EMIT } state_t;
    state_t state;

    // Latched header
    logic [15:0] bm_l;
    logic [4:0]  len_l;
    logic        side_l;
    logic [3:0]  idx_l;
    logic [2:0]  nwords;     // ceil(len/4), 0..4
    logic [2:0]  word_cnt;   // number of received data words

    // Nonzero-byte assembly buffer
    logic [7:0]  nz_buf [0:15];

    // Previous side, used to restart the per-side index.
    logic        prev_side;

    wire cfg_fire  = pe_cfg_valid  & pe_cfg_ready;
    wire data_fire = pe_data_valid & pe_data_ready;

    // Continue the current side index or restart at zero.
    wire [3:0] this_idx   = (pe_cfg_length[15] == prev_side) ? (idx_l + 4'd1) : 4'd0;
    // ceil(len/4), including zero-length fibers.
    wire [2:0] this_nwords = 3'((pe_cfg_length[4:0] + 5'd3) >> 2);

    // Each channel is accepted only in its receive state.
    assign pe_cfg_ready  = (state == S_CFG);
    assign pe_data_ready = (state == S_DATA);

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_CFG;
            bm_l      <= '0;
            len_l     <= '0;
            side_l    <= 1'b0;
            idx_l     <= 4'd0;
            nwords    <= 3'd0;
            word_cnt  <= 3'd0;
            prev_side <= 1'b1;   // makes the first A fiber start at index 0
            for (i = 0; i < 16; i = i + 1) nz_buf[i] <= 8'd0;
        end else begin
            case (state)
                // Latch the header and clear the assembly buffer.
                S_CFG: begin
                    if (cfg_fire) begin
                        side_l    <= pe_cfg_length[15];
                        len_l     <= pe_cfg_length[4:0];
                        bm_l      <= pe_cfg_bitmask;
                        idx_l     <= this_idx;
                        prev_side <= pe_cfg_length[15];
                        nwords    <= this_nwords;
                        word_cnt  <= 3'd0;
                        for (i = 0; i < 16; i = i + 1) nz_buf[i] <= 8'd0;
                        // A zero-length fiber needs no data beats.
                        if (this_nwords == 3'd0) state <= S_EMIT;
                        else                     state <= S_DATA;
                    end
                end
                // Store four bytes from each data beat.
                S_DATA: begin
                    if (data_fire) begin
                        nz_buf[word_cnt*4 + 0] <= pe_data_nzvalue[7:0];
                        nz_buf[word_cnt*4 + 1] <= pe_data_nzvalue[15:8];
                        nz_buf[word_cnt*4 + 2] <= pe_data_nzvalue[23:16];
                        nz_buf[word_cnt*4 + 3] <= pe_data_nzvalue[31:24];
                        if (word_cnt == nwords - 3'd1) state <= S_EMIT;
                        word_cnt <= word_cnt + 3'd1;
                    end
                end
                // Emit the completed fiber for one cycle.
                S_EMIT: begin
                    state <= S_CFG;
                end
                default: state <= S_CFG;
            endcase
        end
    end

    // Output mapping
    assign out_valid   = (state == S_EMIT);
    assign out_bitmask = bm_l;
    assign out_len     = len_l;
    assign out_side    = side_l;
    assign out_idx     = idx_l;

    genvar g;
    generate
        for (g = 0; g < 16; g = g + 1) begin : g_nz_pack
            assign out_nz[g] = nz_buf[g];
        end
    endgenerate

endmodule
