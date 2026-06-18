// TrIP tile compute engine with C-tile accumulation.
//
// This wrapper keeps the existing trip_compute_top as the per-K-chunk engine:
//   A chunk: 2 x 4
//   B chunk: 4 x 2
//   partial C: 2 x 2
//
// External tiling logic writes one A/B K chunk into the inner buffers and pulses
// start_i.  If clear_accum_i is high, the 2x2 C accumulator is cleared before
// adding this chunk.  If clear_accum_i is low, this chunk is accumulated on top
// of previous K chunks for the same output tile.

module trip_tile_compute_engine #(
    parameter NUM_ROWS       = 2,
    parameter NUM_COLS       = 2,
    parameter K_BITS         = 4,
    parameter LANES          = 4,
    parameter DATA_WIDTH     = 16,
    parameter ID_WIDTH       = 4,
    parameter PRODUCT_WIDTH  = DATA_WIDTH * 2,
    parameter ACC_WIDTH      = PRODUCT_WIDTH + $clog2(LANES + 1),
    parameter TILE_ACC_WIDTH = ACC_WIDTH + 8,
    parameter SIGNED_DATA    = 0,
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
    output reg  [CHUNK_CNT_W-1:0]                 chunk_count_o
);

    localparam S_IDLE  = 2'd0;
    localparam S_RUN   = 2'd1;
    localparam S_ACCUM = 2'd2;

    reg [1:0] state;
    reg inner_start;
    reg clear_pending;

    wire inner_done;
    reg [TILE_ACC_WIDTH-1:0] tile_accum [0:NUM_OUTPUTS-1];

    trip_compute_top #(
        .NUM_ROWS      (NUM_ROWS),
        .NUM_COLS      (NUM_COLS),
        .K_BITS        (K_BITS),
        .LANES         (LANES),
        .DATA_WIDTH    (DATA_WIDTH),
        .ID_WIDTH      (ID_WIDTH),
        .PRODUCT_WIDTH (PRODUCT_WIDTH),
        .ACC_WIDTH     (ACC_WIDTH),
        .SIGNED_DATA   (SIGNED_DATA)
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

    genvar go;
    generate
        for (go = 0; go < NUM_OUTPUTS; go = go + 1) begin : gen_tile_result
            assign tile_result_o[go*TILE_ACC_WIDTH +: TILE_ACC_WIDTH] = tile_accum[go];
        end
    endgenerate

    integer i;
    reg [ACC_WIDTH-1:0] partial_word;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state           <= S_IDLE;
            inner_start     <= 1'b0;
            clear_pending   <= 1'b0;
            busy_o          <= 1'b0;
            done_o          <= 1'b0;
            overflow_seen_o <= 1'b0;
            tile_valid_o    <= {NUM_OUTPUTS{1'b0}};
            chunk_count_o   <= {CHUNK_CNT_W{1'b0}};
            for (i = 0; i < NUM_OUTPUTS; i = i + 1)
                tile_accum[i] <= {TILE_ACC_WIDTH{1'b0}};
        end else begin
            inner_start <= 1'b0;
            done_o      <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy_o <= 1'b0;
                    if (start_i) begin
                        busy_o        <= 1'b1;
                        inner_start   <= 1'b1;
                        clear_pending <= clear_accum_i;

                        if (clear_accum_i) begin
                            overflow_seen_o <= 1'b0;
                            tile_valid_o    <= {NUM_OUTPUTS{1'b0}};
                            chunk_count_o   <= {CHUNK_CNT_W{1'b0}};
                            for (i = 0; i < NUM_OUTPUTS; i = i + 1)
                                tile_accum[i] <= {TILE_ACC_WIDTH{1'b0}};
                        end

                        state <= S_RUN;
                    end
                end

                S_RUN: begin
                    busy_o <= 1'b1;
                    if (inner_done)
                        state <= S_ACCUM;
                end

                // Wait one cycle after inner_done so trip_compute_top's row
                // buffer outputs are stable, then fold this partial C tile into
                // the outer C-tile accumulator.
                S_ACCUM: begin
                    for (i = 0; i < NUM_OUTPUTS; i = i + 1) begin
                        partial_word = partial_result_o[i*ACC_WIDTH +: ACC_WIDTH];
                        if (partial_valid_o[i]) begin
                            tile_accum[i] <= tile_accum[i] +
                                (SIGNED_DATA ?
                                    {{(TILE_ACC_WIDTH-ACC_WIDTH){partial_word[ACC_WIDTH-1]}}, partial_word} :
                                    {{(TILE_ACC_WIDTH-ACC_WIDTH){1'b0}}, partial_word});
                            tile_valid_o[i] <= 1'b1;
                        end else if (clear_pending) begin
                            tile_accum[i] <= {TILE_ACC_WIDTH{1'b0}};
                            tile_valid_o[i] <= 1'b0;
                        end
                    end

                    overflow_seen_o <= overflow_seen_o | overflow_o;
                    chunk_count_o   <= chunk_count_o + 1'b1;
                    busy_o          <= 1'b0;
                    done_o          <= 1'b1;
                    state           <= S_IDLE;
                end

                default: begin
                    state  <= S_IDLE;
                    busy_o <= 1'b0;
                end
            endcase
        end
    end

endmodule
