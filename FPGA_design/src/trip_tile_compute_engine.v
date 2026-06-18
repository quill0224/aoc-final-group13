// TrIP tile compute engine with C-tile accumulation.
//
// Wraps trip_compute_top (single K-chunk) with a C-tile accumulator that
// accumulates across multiple K-chunks.
//
// Direct MFIU mode requires LANES == NUM_ROWS * NUM_COLS * K_BITS.
// Packed MFIU mode treats LANES as effectual-MAC capacity, e.g. 128 lanes for
// a 4-row x 4-column Trapezoid-style MFIU.
//
// FSM style: three always blocks (state register / next-state combo /
// registered output logic) per coding guideline rule 5/10.
//
// DFT: test_mode_i gates fsm_state_obs_o for observability.  scan_en_i is
// reserved for DFT-tool-inserted scan chain; not used in RTL.
// All FFs use async reset and are scan-transparent (no gated clocks).

module trip_tile_compute_engine #(
    parameter NUM_ROWS       = 4,
    parameter NUM_COLS       = 4,
    parameter K_BITS         = 4,
    parameter LANES          = 64,
    parameter DATA_WIDTH     = 16,
    parameter ID_WIDTH       = 4,
    parameter PRODUCT_WIDTH  = DATA_WIDTH * 2,
    parameter ACC_WIDTH      = PRODUCT_WIDTH + $clog2(LANES + 1),
    parameter TILE_ACC_WIDTH = ACC_WIDTH + 8,
    parameter SIGNED_DATA    = 0,
    parameter PACKED_MFIU    = 0,
    // derived
    parameter ADDR_W_A       = (NUM_ROWS > 1) ? $clog2(NUM_ROWS) : 1,
    parameter ADDR_W_B       = (NUM_COLS > 1) ? $clog2(NUM_COLS) : 1,
    parameter CNT_W          = $clog2(LANES + 1),
    parameter NUM_OUTPUTS    = NUM_ROWS * NUM_COLS,
    parameter CHUNK_CNT_W    = 8
) (
    input  wire clk,
    input  wire reset,

    input  wire                           a_wr_en_i,
    input  wire [ADDR_W_A-1:0]            a_wr_addr_i,
    input  wire [ID_WIDTH-1:0]            a_wr_id_i,
    input  wire [K_BITS-1:0]              a_wr_mask_i,
    input  wire [K_BITS*DATA_WIDTH-1:0]   a_wr_values_i,

    input  wire                           b_wr_en_i,
    input  wire [ADDR_W_B-1:0]            b_wr_addr_i,
    input  wire [ID_WIDTH-1:0]            b_wr_id_i,
    input  wire [K_BITS-1:0]              b_wr_mask_i,
    input  wire [K_BITS*DATA_WIDTH-1:0]   b_wr_values_i,

    input  wire start_i,
    input  wire clear_accum_i,
    output reg  busy_o,
    output reg  done_o,

    output wire [NUM_OUTPUTS-1:0]                 partial_valid_o,
    output wire [NUM_OUTPUTS*ACC_WIDTH-1:0]       partial_result_o,
    output wire [CNT_W-1:0]                       match_count_o,
    output wire                                   overflow_o,
    output reg                                    overflow_seen_o,

    output reg  [NUM_OUTPUTS-1:0]                 tile_valid_o,
    output wire [NUM_OUTPUTS*TILE_ACC_WIDTH-1:0]  tile_result_o,
    output reg  [CHUNK_CNT_W-1:0]                 chunk_count_o,

    // ── DFT ports ─────────────────────────────────────────────────────────────
    input  wire test_mode_i,   // high during structural test
    input  wire scan_en_i,     // reserved: connected by DFT insertion tool
    output wire [1:0] fsm_state_obs_o  // observability: FSM state in test mode
);

    // ── Elaboration-time parameter guard ─────────────────────────────────────
    initial begin
        if (!PACKED_MFIU && (LANES !== NUM_ROWS * NUM_COLS * K_BITS)) begin
            $display("FATAL [trip_tile_compute_engine]: direct mode LANES=%0d must equal NUM_ROWS*NUM_COLS*K_BITS=%0d",
                     LANES, NUM_ROWS * NUM_COLS * K_BITS);
            $finish;
        end
    end

    // ── FSM encoding ──────────────────────────────────────────────────────────
    localparam S_IDLE   = 2'd0;
    localparam S_RUN    = 2'd1;
    localparam S_ACCUM  = 2'd2;
    localparam S_REPLAY = 2'd3;   // inactive when LANES = total combinations

    // ── State registers ───────────────────────────────────────────────────────
    reg [1:0] state;
    reg [1:0] next_state;

    // ── Datapath registers ────────────────────────────────────────────────────
    reg inner_start;
    reg clear_pending;
    reg [7:0] replay_pass;
    reg [TILE_ACC_WIDTH-1:0] tile_accum [0:NUM_OUTPUTS-1];

    wire inner_done;

    // ── Inner compute (single K-chunk) ────────────────────────────────────────
    trip_compute_top #(
        .NUM_ROWS      (NUM_ROWS),
        .NUM_COLS      (NUM_COLS),
        .K_BITS        (K_BITS),
        .LANES         (LANES),
        .DATA_WIDTH    (DATA_WIDTH),
        .ID_WIDTH      (ID_WIDTH),
        .PRODUCT_WIDTH (PRODUCT_WIDTH),
        .ACC_WIDTH     (ACC_WIDTH),
        .SIGNED_DATA   (SIGNED_DATA),
        .PACKED_MFIU   (PACKED_MFIU)
    ) u_chunk_compute (
        .clk            (clk),
        .reset          (reset),
        .a_wr_en_i      (a_wr_en_i),
        .a_wr_addr_i    (a_wr_addr_i),
        .a_wr_id_i      (a_wr_id_i),
        .a_wr_mask_i    (a_wr_mask_i),
        .a_wr_values_i  (a_wr_values_i),
        .b_wr_en_i      (b_wr_en_i),
        .b_wr_addr_i    (b_wr_addr_i),
        .b_wr_id_i      (b_wr_id_i),
        .b_wr_mask_i    (b_wr_mask_i),
        .b_wr_values_i  (b_wr_values_i),
        .start_i        (inner_start),
        .done_o         (inner_done),
        .result_valid_o (partial_valid_o),
        .result_o       (partial_result_o),
        .match_count_o  (match_count_o),
        .overflow_o     (overflow_o)
    );

    // ── Tile result readout ───────────────────────────────────────────────────
    genvar go;
    generate
        for (go = 0; go < NUM_OUTPUTS; go = go + 1) begin : gen_tile_result
            assign tile_result_o[go*TILE_ACC_WIDTH +: TILE_ACC_WIDTH] = tile_accum[go];
        end
    endgenerate

    // ── Sign-extended partial products (combinational, rule 9) ───────────────
    // Flat bus: partial_words_ext[i*TILE_ACC_WIDTH +: TILE_ACC_WIDTH] = slot i.
    // Pure wire — no FF inferred.  Replaces the old reg partial_word that was
    // assigned with blocking = inside a clocked always block (bad practice).
    wire [NUM_OUTPUTS*TILE_ACC_WIDTH-1:0] partial_words_ext;
    genvar pw_g;
    generate
        for (pw_g = 0; pw_g < NUM_OUTPUTS; pw_g = pw_g + 1) begin : gen_pw
            assign partial_words_ext[pw_g*TILE_ACC_WIDTH +: TILE_ACC_WIDTH] = SIGNED_DATA ?
                {{(TILE_ACC_WIDTH-ACC_WIDTH){partial_result_o[(pw_g+1)*ACC_WIDTH-1]}},
                  partial_result_o[pw_g*ACC_WIDTH +: ACC_WIDTH]} :
                {{(TILE_ACC_WIDTH-ACC_WIDTH){1'b0}},
                  partial_result_o[pw_g*ACC_WIDTH +: ACC_WIDTH]};
        end
    endgenerate

    // ── DFT: FSM state observability ─────────────────────────────────────────
    assign fsm_state_obs_o = test_mode_i ? state : 2'b00;

    // ── Block 1: State register ───────────────────────────────────────────────
    always @(posedge clk or posedge reset) begin
        if (reset) state <= S_IDLE;
        else        state <= next_state;
    end

    // ── Block 2: Next-state combinational logic ───────────────────────────────
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:   next_state = start_i    ? S_RUN    : S_IDLE;
            S_RUN:    next_state = inner_done  ? S_ACCUM  : S_RUN;
            S_ACCUM:  next_state = overflow_o  ? S_REPLAY : S_IDLE;
            S_REPLAY: next_state = S_RUN;
            default:  next_state = S_IDLE;
        endcase
    end

    // ── Block 3: Registered output logic ─────────────────────────────────────
    integer i;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            inner_start     <= 1'b0;
            clear_pending   <= 1'b0;
            busy_o          <= 1'b0;
            done_o          <= 1'b0;
            overflow_seen_o <= 1'b0;
            tile_valid_o    <= {NUM_OUTPUTS{1'b0}};
            chunk_count_o   <= {CHUNK_CNT_W{1'b0}};
            replay_pass     <= 8'd0;
            for (i = 0; i < NUM_OUTPUTS; i = i + 1)
                tile_accum[i] <= {TILE_ACC_WIDTH{1'b0}};
        end else begin
            // ── Pulse defaults (deassert every cycle unless re-asserted) ──────
            inner_start <= 1'b0;
            done_o      <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy_o <= 1'b0;
                    if (start_i) begin
                        busy_o        <= 1'b1;
                        inner_start   <= 1'b1;
                        clear_pending <= clear_accum_i;
                        replay_pass   <= 8'd0;
                        if (clear_accum_i) begin
                            overflow_seen_o <= 1'b0;
                            tile_valid_o    <= {NUM_OUTPUTS{1'b0}};
                            chunk_count_o   <= {CHUNK_CNT_W{1'b0}};
                            for (i = 0; i < NUM_OUTPUTS; i = i + 1)
                                tile_accum[i] <= {TILE_ACC_WIDTH{1'b0}};
                        end
                    end
                end

                S_RUN: begin
                    busy_o <= 1'b1;
                end

                // One cycle after inner_done: partial_result_o is stable.
                // Fold this K-chunk's partial C tile into the outer accumulator.
                S_ACCUM: begin
                    for (i = 0; i < NUM_OUTPUTS; i = i + 1) begin
                        if (partial_valid_o[i]) begin
                            tile_accum[i]   <= tile_accum[i] +
                                               partial_words_ext[i*TILE_ACC_WIDTH +: TILE_ACC_WIDTH];
                            tile_valid_o[i] <= 1'b1;
                        end else if (clear_pending) begin
                            tile_accum[i]   <= {TILE_ACC_WIDTH{1'b0}};
                            tile_valid_o[i] <= 1'b0;
                        end
                    end
                    overflow_seen_o <= overflow_seen_o | overflow_o;
                    if (overflow_o) begin
                        replay_pass <= replay_pass + 8'd1;
                        busy_o      <= 1'b1;
                    end else begin
                        chunk_count_o <= chunk_count_o + 1'b1;
                        busy_o        <= 1'b0;
                        done_o        <= 1'b1;
                    end
                end

                // Re-issue inner compute for same K-chunk (future: pass
                // replay_pass to MFIU skip_count_i to skip already-processed
                // effectual MACs).  In direct mode this state is never reached.
                S_REPLAY: begin
                    busy_o        <= 1'b1;
                    inner_start   <= 1'b1;
                    clear_pending <= 1'b0;
                end

                default: begin
                    busy_o <= 1'b0;
                end
            endcase
        end
    end

endmodule
