// mfiu.v — Multi-Fiber Intersection Unit  (V0: combinational scanner)
//
// For each (row, col) fiber pair, computes a_mask & b_mask to find every k-slot
// where both A and B are nonzero (an "effectual" MAC).  The hits are packed
// in (r, c, k) scan order into LANES output slots.
//
// Outputs feed directly into distribution_network:
//   lane_valid_o  — which lanes carry a valid pair
//   a_row_sel_o   — which A fiber to read for that lane
//   b_col_sel_o   — which B fiber to read for that lane
//   k_sel_o       — which slot index inside the fiber
//
// overflow_o goes high when effectual MACs > LANES; the caller must replay.
//
// Implementation note:
//   Variable part-selects on packed output regs ([lane_ptr*W +: W]) in
//   always @(*) blocks are unreliable in ModelSim Verilog-2001 mode.
//   Fix: use unpacked reg arrays internally (variable array index IS legal),
//   then pack to output wires via generate with constant genvar indices.
//
// See HARDWARE_STRUCTURE.md §22 for interface spec, §29 for worked example.

module mfiu #(
    parameter NUM_ROWS  = 4,           // = N_A_FIBER
    parameter NUM_COLS  = 4,           // = N_B_FIBER
    parameter K_BITS    = 16,          // = BITMASK_W
    parameter LANES     = 16,          // = N_MUL_ROW (max effectual MACs captured per cycle)
    // derived — do not override
    parameter ROW_IDX_W = (NUM_ROWS > 1) ? $clog2(NUM_ROWS) : 1,
    parameter COL_IDX_W = (NUM_COLS > 1) ? $clog2(NUM_COLS) : 1,
    parameter K_IDX_W   = (K_BITS   > 1) ? $clog2(K_BITS)   : 1,
    parameter CNT_W     = $clog2(LANES + 1)
) (
    // Bitmasks: fiber r lives at a_mask_i[r*K_BITS +: K_BITS]
    input  wire [NUM_ROWS*K_BITS-1:0]           a_mask_i,
    input  wire [NUM_COLS*K_BITS-1:0]           b_mask_i,

    // Per-lane routing metadata (packed, LSB = lane 0)
    output wire [LANES-1:0]                      lane_valid_o,
    output wire [LANES*ROW_IDX_W-1:0]            a_row_sel_o,
    output wire [LANES*COL_IDX_W-1:0]            b_col_sel_o,
    output wire [LANES*K_IDX_W-1:0]              k_sel_o,

    output reg  [CNT_W-1:0]                      match_count_o, // lanes filled (0..LANES)
    output reg                                   overflow_o     // effectual > LANES
);

    // Internal unpacked arrays — variable array indexing is well-defined in
    // Verilog-2001, unlike variable part-selects on packed regs.
    reg                  lane_vld [0:LANES-1];
    reg [ROW_IDX_W-1:0] lane_row [0:LANES-1];
    reg [COL_IDX_W-1:0] lane_col [0:LANES-1];
    reg [K_IDX_W-1:0]   lane_k   [0:LANES-1];

    integer r, c, k;
    integer lane_ptr;   // next free lane slot (0..LANES)
    integer total;      // all effectual hits including overflow ones
    integer il;

    always @(*) begin
        for (il = 0; il < LANES; il = il + 1) begin
            lane_vld[il] = 1'b0;
            lane_row[il] = {ROW_IDX_W{1'b0}};
            lane_col[il] = {COL_IDX_W{1'b0}};
            lane_k  [il] = {K_IDX_W{1'b0}};
        end
        match_count_o = {CNT_W{1'b0}};
        overflow_o    = 1'b0;
        lane_ptr      = 0;
        total         = 0;

        for (r = 0; r < NUM_ROWS; r = r + 1) begin
            for (c = 0; c < NUM_COLS; c = c + 1) begin
                for (k = 0; k < K_BITS; k = k + 1) begin
                    if (a_mask_i[r*K_BITS + k] & b_mask_i[c*K_BITS + k]) begin
                        total = total + 1;
                        if (lane_ptr < LANES) begin
                            lane_vld[lane_ptr] = 1'b1;
                            lane_row[lane_ptr] = r[ROW_IDX_W-1:0];
                            lane_col[lane_ptr] = c[COL_IDX_W-1:0];
                            lane_k  [lane_ptr] = k[K_IDX_W-1:0];
                            lane_ptr = lane_ptr + 1;
                        end
                    end
                end
            end
        end

        match_count_o = lane_ptr[CNT_W-1:0];
        overflow_o    = (total > LANES) ? 1'b1 : 1'b0;
    end

    // Pack internal arrays to output wires using constant genvar — no
    // variable part-selects here, so this is safe in all Verilog-2001 tools.
    genvar gl;
    generate
        for (gl = 0; gl < LANES; gl = gl + 1) begin : gen_pack
            assign lane_valid_o[gl]                         = lane_vld[gl];
            assign a_row_sel_o [gl*ROW_IDX_W +: ROW_IDX_W] = lane_row[gl];
            assign b_col_sel_o [gl*COL_IDX_W +: COL_IDX_W] = lane_col[gl];
            assign k_sel_o     [gl*K_IDX_W   +: K_IDX_W]   = lane_k[gl];
        end
    endgenerate

endmodule
