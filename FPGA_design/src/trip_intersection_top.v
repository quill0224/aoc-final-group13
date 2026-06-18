// trip_intersection_top.v — TrIP intersection front-end
//
// Wires A/B bitmask_buffers to the MFIU.
// On start_i: reads all fiber masks one-by-one (1-cycle read latency per fiber),
// then presents the assembled masks to MFIU.  done_o pulses for exactly one
// cycle when MFIU outputs are valid.
//
// Timing for NUM_ROWS = NUM_COLS = 4 (MAX_FIBERS = 4):
//   T+0  start_i asserted — buffer already pre-reading addr 0, prefetch addr 1
//   T+1  S_READ: capture mask[0], prefetch addr 2
//   T+2  S_READ: capture mask[1], prefetch addr 3
//   T+3  S_READ: capture mask[2], prefetch addr 4
//   T+4  S_READ: capture mask[3] — last fiber
//   T+5  S_DONE: done_o = 1, direct MFIU outputs valid
// Packed MFIU mode adds a registered MFIU pipeline before done_o.
//
// See HARDWARE_STRUCTURE.md §12.5.4 (MFIU), Phase 1.

module trip_intersection_top #(
    parameter NUM_ROWS   = 4,
    parameter NUM_COLS   = 4,
    parameter K_BITS     = 4,
    parameter LANES      = 64,
    parameter DATA_WIDTH = 16,
    parameter ID_WIDTH   = 4,
    parameter PACKED_MFIU = 0,
    // derived — do not override
    parameter ADDR_W_A   = (NUM_ROWS > 1) ? $clog2(NUM_ROWS) : 1,
    parameter ADDR_W_B   = (NUM_COLS > 1) ? $clog2(NUM_COLS) : 1,
    parameter ROW_IDX_W  = (NUM_ROWS > 1) ? $clog2(NUM_ROWS) : 1,
    parameter COL_IDX_W  = (NUM_COLS > 1) ? $clog2(NUM_COLS) : 1,
    parameter K_IDX_W    = (K_BITS   > 1) ? $clog2(K_BITS)   : 1,
    parameter ACTIVE_COLS_W = (NUM_COLS > 1) ? $clog2(NUM_COLS + 1) : 1,
    parameter CNT_W      = $clog2(LANES + 1),
    parameter TOTAL_CANDIDATES = NUM_ROWS * NUM_COLS * K_BITS,
    parameter EVENT_CNT_W = $clog2(TOTAL_CANDIDATES + 1),
    parameter MAX_FIBERS = (NUM_ROWS > NUM_COLS) ? NUM_ROWS : NUM_COLS,
    parameter FC_W       = (MAX_FIBERS > 1) ? $clog2(MAX_FIBERS + 1) : 2
) (
    input  wire clk,
    input  wire reset,

    // ── A-buffer write port ──────────────────────────────────────────────────
    input  wire                            a_wr_en_i,
    input  wire [ADDR_W_A-1:0]            a_wr_addr_i,
    input  wire [ID_WIDTH-1:0]            a_wr_id_i,
    input  wire [K_BITS-1:0]             a_wr_mask_i,
    input  wire [K_BITS*DATA_WIDTH-1:0]  a_wr_values_i,

    // ── B-buffer write port ──────────────────────────────────────────────────
    input  wire                            b_wr_en_i,
    input  wire [ADDR_W_B-1:0]            b_wr_addr_i,
    input  wire [ID_WIDTH-1:0]            b_wr_id_i,
    input  wire [K_BITS-1:0]             b_wr_mask_i,
    input  wire [K_BITS*DATA_WIDTH-1:0]  b_wr_values_i,

    // ── Control ──────────────────────────────────────────────────────────────
    input  wire start_i,
    input  wire [EVENT_CNT_W-1:0] replay_skip_i,
    output reg  done_o,    // one-cycle pulse — sample MFIU outputs when high

    // ── MFIU outputs (valid when done_o = 1) ─────────────────────────────────
    output wire [LANES-1:0]              lane_valid_o,
    output wire [LANES*ROW_IDX_W-1:0]   a_row_sel_o,
    output wire [LANES*COL_IDX_W-1:0]   b_col_sel_o,
    output wire [LANES*K_IDX_W-1:0]     k_sel_o,
    output wire [CNT_W-1:0]             match_count_o,
    output wire [ACTIVE_COLS_W-1:0]     active_b_cols_o,
    output wire                          overflow_o,

    // Captured fixed-slot values, valid when done_o = 1.
    output wire [NUM_ROWS*K_BITS*DATA_WIDTH-1:0] a_values_o,
    output wire [NUM_COLS*K_BITS*DATA_WIDTH-1:0] b_values_o
);

    // ── FSM ──────────────────────────────────────────────────────────────────
    localparam S_IDLE       = 3'd0;
    localparam S_READ       = 3'd1;
    localparam S_MFIU_START = 3'd2;
    localparam S_MFIU_WAIT  = 3'd3;
    localparam S_DONE       = 3'd4;

    reg [2:0]      state;
    reg [FC_W-1:0] fiber_cnt;   // which fiber is on the buffer output this cycle
    reg            mfiu_start;

    // ── Buffer read-side signals ──────────────────────────────────────────────
    reg  [ADDR_W_A-1:0]           rd_addr_a;
    wire [K_BITS-1:0]             buf_a_mask;
    wire [K_BITS*DATA_WIDTH-1:0]  buf_a_values;
    // (rd_id_o, k_value_o unused in this version)

    reg  [ADDR_W_B-1:0]           rd_addr_b;
    wire [K_BITS-1:0]             buf_b_mask;
    wire [K_BITS*DATA_WIDTH-1:0]  buf_b_values;

    // Captured mask registers fed to MFIU
    reg  [K_BITS-1:0]             a_mask_reg [0:NUM_ROWS-1];
    reg  [K_BITS-1:0]             b_mask_reg [0:NUM_COLS-1];
    reg  [K_BITS*DATA_WIDTH-1:0]  a_value_reg [0:NUM_ROWS-1];
    reg  [K_BITS*DATA_WIDTH-1:0]  b_value_reg [0:NUM_COLS-1];

    // Packed mask buses for MFIU: fiber r at [r*K_BITS +: K_BITS]
    wire [NUM_ROWS*K_BITS-1:0]    a_masks_mfiu;
    wire [NUM_COLS*K_BITS-1:0]    b_masks_mfiu;
    wire                          mfiu_pipe_valid;

    wire [FC_W-1:0] prefetch_addr;
    assign prefetch_addr = fiber_cnt + 2;

    // ── A bitmask_buffer ──────────────────────────────────────────────────────
    bitmask_buffer #(
        .NUM_FIBERS (NUM_ROWS),
        .K_BITS     (K_BITS),
        .DATA_WIDTH (DATA_WIDTH),
        .ID_WIDTH   (ID_WIDTH)
    ) u_a_buf (
        .clk         (clk),
        .reset       (reset),
        .wr_en_i     (a_wr_en_i),
        .wr_addr_i   (a_wr_addr_i),
        .wr_id_i     (a_wr_id_i),
        .wr_mask_i   (a_wr_mask_i),
        .wr_values_i (a_wr_values_i),
        .rd_addr_i   (rd_addr_a),
        .rd_id_o     (),
        .rd_mask_o   (buf_a_mask),
        .rd_values_o (buf_a_values),
        .k_sel_i     ({K_IDX_W{1'b0}}),
        .k_value_o   ()
    );

    // ── B bitmask_buffer ──────────────────────────────────────────────────────
    bitmask_buffer #(
        .NUM_FIBERS (NUM_COLS),
        .K_BITS     (K_BITS),
        .DATA_WIDTH (DATA_WIDTH),
        .ID_WIDTH   (ID_WIDTH)
    ) u_b_buf (
        .clk         (clk),
        .reset       (reset),
        .wr_en_i     (b_wr_en_i),
        .wr_addr_i   (b_wr_addr_i),
        .wr_id_i     (b_wr_id_i),
        .wr_mask_i   (b_wr_mask_i),
        .wr_values_i (b_wr_values_i),
        .rd_addr_i   (rd_addr_b),
        .rd_id_o     (),
        .rd_mask_o   (buf_b_mask),
        .rd_values_o (buf_b_values),
        .k_sel_i     ({K_IDX_W{1'b0}}),
        .k_value_o   ()
    );

    // ── Mask assembly for MFIU ────────────────────────────────────────────────
    genvar ga, gb, gva, gvb;
    generate
        for (ga = 0; ga < NUM_ROWS; ga = ga + 1) begin : gen_a
            assign a_masks_mfiu[ga*K_BITS +: K_BITS] = a_mask_reg[ga];
        end
        for (gb = 0; gb < NUM_COLS; gb = gb + 1) begin : gen_b
            assign b_masks_mfiu[gb*K_BITS +: K_BITS] = b_mask_reg[gb];
        end
        for (gva = 0; gva < NUM_ROWS; gva = gva + 1) begin : gen_a_values
            assign a_values_o[gva*K_BITS*DATA_WIDTH +: K_BITS*DATA_WIDTH] = a_value_reg[gva];
        end
        for (gvb = 0; gvb < NUM_COLS; gvb = gvb + 1) begin : gen_b_values
            assign b_values_o[gvb*K_BITS*DATA_WIDTH +: K_BITS*DATA_WIDTH] = b_value_reg[gvb];
        end
    endgenerate

    // ── MFIU ──────────────────────────────────────────────────────────────────
    generate
        if (PACKED_MFIU) begin : gen_packed_mfiu
            mfiu_pipelined #(
                .NUM_ROWS (NUM_ROWS),
                .NUM_COLS (NUM_COLS),
                .K_BITS   (K_BITS),
                .LANES    (LANES)
            ) u_mfiu (
                .clk           (clk),
                .reset         (reset),
                .valid_i       (mfiu_start),
                .replay_skip_i (replay_skip_i),
                .a_mask_i      (a_masks_mfiu),
                .b_mask_i      (b_masks_mfiu),
                .valid_o       (mfiu_pipe_valid),
                .lane_valid_o  (lane_valid_o),
                .a_row_sel_o   (a_row_sel_o),
                .b_col_sel_o   (b_col_sel_o),
                .k_sel_o       (k_sel_o),
                .match_count_o (match_count_o),
                .active_b_cols_o(active_b_cols_o),
                .overflow_o    (overflow_o)
            );
        end else begin : gen_direct_mfiu
            assign mfiu_pipe_valid = 1'b0;

            mfiu #(
                .NUM_ROWS (NUM_ROWS),
                .NUM_COLS (NUM_COLS),
                .K_BITS   (K_BITS),
                .LANES    (LANES),
                .PACKED_MODE (1'b0)
            ) u_mfiu (
                .a_mask_i      (a_masks_mfiu),
                .b_mask_i      (b_masks_mfiu),
                .lane_valid_o  (lane_valid_o),
                .a_row_sel_o   (a_row_sel_o),
                .b_col_sel_o   (b_col_sel_o),
                .k_sel_o       (k_sel_o),
                .match_count_o (match_count_o),
                .active_b_cols_o(active_b_cols_o),
                .overflow_o    (overflow_o)
            );
        end
    endgenerate

    // ── FSM: read all fiber masks then trigger MFIU ───────────────────────────
    integer ri;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state     <= S_IDLE;
            fiber_cnt <= {FC_W{1'b0}};
            done_o    <= 1'b0;
            mfiu_start <= 1'b0;
            rd_addr_a <= {ADDR_W_A{1'b0}};
            rd_addr_b <= {ADDR_W_B{1'b0}};
            for (ri = 0; ri < NUM_ROWS; ri = ri + 1) a_mask_reg[ri] <= {K_BITS{1'b0}};
            for (ri = 0; ri < NUM_COLS; ri = ri + 1) b_mask_reg[ri] <= {K_BITS{1'b0}};
            for (ri = 0; ri < NUM_ROWS; ri = ri + 1) a_value_reg[ri] <= {(K_BITS*DATA_WIDTH){1'b0}};
            for (ri = 0; ri < NUM_COLS; ri = ri + 1) b_value_reg[ri] <= {(K_BITS*DATA_WIDTH){1'b0}};
        end else begin
            done_o <= 1'b0;  // default: pulse is low
            mfiu_start <= 1'b0;

            case (state)

                // Hold rd_addr = 0 so the buffer pre-reads fiber 0 every cycle.
                // The moment start_i fires the output already holds mask[0].
                // Because bitmask_buffer has registered read outputs, issue
                // addr 1 here so mask[1] is ready by the second S_READ cycle.
                S_IDLE: begin
                    rd_addr_a <= {ADDR_W_A{1'b0}};
                    rd_addr_b <= {ADDR_W_B{1'b0}};
                    if (start_i) begin
                        fiber_cnt <= {FC_W{1'b0}};
                        if (NUM_ROWS > 1) rd_addr_a <= 1'b1;
                        if (NUM_COLS > 1) rd_addr_b <= 1'b1;
                        state     <= S_READ;
                    end
                end

                // Each cycle: capture mask[fiber_cnt] from buffer output,
                // then prefetch the fiber after the one already in flight.
                S_READ: begin
                    for (ri = 0; ri < NUM_ROWS; ri = ri + 1) begin
                        if (fiber_cnt == ri[FC_W-1:0]) begin
                            a_mask_reg[ri]  <= buf_a_mask;
                            a_value_reg[ri] <= buf_a_values;
                        end
                    end
                    for (ri = 0; ri < NUM_COLS; ri = ri + 1) begin
                        if (fiber_cnt == ri[FC_W-1:0]) begin
                            b_mask_reg[ri]  <= buf_b_mask;
                            b_value_reg[ri] <= buf_b_values;
                        end
                    end

                    fiber_cnt <= fiber_cnt + 1'b1;

                    if (fiber_cnt == MAX_FIBERS - 1) begin
                        if (PACKED_MFIU)
                            state <= S_MFIU_START;
                        else
                            state <= S_DONE;
                    end else begin
                        if (prefetch_addr < NUM_ROWS) rd_addr_a <= prefetch_addr[ADDR_W_A-1:0];
                        if (prefetch_addr < NUM_COLS) rd_addr_b <= prefetch_addr[ADDR_W_B-1:0];
                    end
                end

                // Start the packed MFIU one cycle after the final mask capture,
                // so the assembled mask registers are stable at its input.
                S_MFIU_START: begin
                    mfiu_start <= 1'b1;
                    state <= S_MFIU_WAIT;
                end

                S_MFIU_WAIT: begin
                    if (mfiu_pipe_valid) begin
                        done_o    <= 1'b1;
                        rd_addr_a <= {ADDR_W_A{1'b0}};
                        rd_addr_b <= {ADDR_W_B{1'b0}};
                        state     <= S_IDLE;
                    end
                end

                // All masks captured; MFIU output is combinationally valid.
                S_DONE: begin
                    done_o    <= 1'b1;
                    rd_addr_a <= {ADDR_W_A{1'b0}};
                    rd_addr_b <= {ADDR_W_B{1'b0}};
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
