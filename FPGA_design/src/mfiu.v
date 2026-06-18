// mfiu.v — Multi-Fiber Intersection Unit.
//
// Packed TrIP-style MFIU:
//   1. Computes all pairwise A-row/B-column bitmask intersections.
//   2. Scans effectual (row, col, k) matches in row -> column -> k order.
//   3. Packs only effectual MACs into lane 0..LANES-1 and emits routing
//      metadata for the A/B distribution networks.
//
// This approximates the paper's MFIU prefix/shift behavior at RTL level while
// keeping the PE multiplier lanes unchanged.

module mfiu #(
    parameter NUM_ROWS  = 4,
    parameter NUM_COLS  = 4,
    parameter K_BITS    = 4,
    parameter LANES     = NUM_ROWS * NUM_COLS * K_BITS,
    parameter PACKED_MODE = 0,
    // derived — do not override
    parameter ROW_IDX_W = (NUM_ROWS > 1) ? $clog2(NUM_ROWS) : 1,
    parameter COL_IDX_W = (NUM_COLS > 1) ? $clog2(NUM_COLS) : 1,
    parameter K_IDX_W   = (K_BITS   > 1) ? $clog2(K_BITS)   : 1,
    parameter ACTIVE_COLS_W = (NUM_COLS > 1) ? $clog2(NUM_COLS + 1) : 1,
    parameter CNT_W     = $clog2(LANES + 1),
    parameter TOTAL_CANDIDATES = NUM_ROWS * NUM_COLS * K_BITS,
    parameter POLICY_CNT_W = $clog2(TOTAL_CANDIDATES + 1)
) (
    input  wire [NUM_ROWS*K_BITS-1:0]           a_mask_i,
    input  wire [NUM_COLS*K_BITS-1:0]           b_mask_i,

    output reg  [LANES-1:0]                      lane_valid_o,
    output reg  [LANES*ROW_IDX_W-1:0]            a_row_sel_o,
    output reg  [LANES*COL_IDX_W-1:0]            b_col_sel_o,
    output reg  [LANES*K_IDX_W-1:0]              k_sel_o,

    output reg  [CNT_W-1:0]                      match_count_o,
    output reg  [ACTIVE_COLS_W-1:0]              active_b_cols_o,
    output reg                                   overflow_o
);

    reg [TOTAL_CANDIDATES-1:0] event_valid;
    reg [POLICY_CNT_W-1:0] event_rank [0:TOTAL_CANDIDATES-1];
    reg [POLICY_CNT_W-1:0] col_group_count [0:NUM_COLS-1];
    integer e_i, p_i, l_i;
    integer r_i, c_i, k_i;
    integer ev_r, ev_c, ev_k;
    always @(*) begin
        lane_valid_o = {LANES{1'b0}};
        a_row_sel_o  = {(LANES*ROW_IDX_W){1'b0}};
        b_col_sel_o  = {(LANES*COL_IDX_W){1'b0}};
        k_sel_o      = {(LANES*K_IDX_W){1'b0}};
        match_count_o = {CNT_W{1'b0}};
        active_b_cols_o = {ACTIVE_COLS_W{1'b0}};
        overflow_o = 1'b0;
        ev_r = 0;
        ev_c = 0;
        ev_k = 0;
        for (e_i = 0; e_i < TOTAL_CANDIDATES; e_i = e_i + 1) begin
            event_valid[e_i] = 1'b0;
            event_rank[e_i] = {POLICY_CNT_W{1'b0}};
        end
        for (c_i = 0; c_i < NUM_COLS; c_i = c_i + 1)
            col_group_count[c_i] = {POLICY_CNT_W{1'b0}};

        if (PACKED_MODE) begin
            for (c_i = 0; c_i < NUM_COLS; c_i = c_i + 1) begin
                col_group_count[c_i] = (c_i == 0) ? {POLICY_CNT_W{1'b0}} : col_group_count[c_i-1];
                for (r_i = 0; r_i < NUM_ROWS; r_i = r_i + 1) begin
                    for (k_i = 0; k_i < K_BITS; k_i = k_i + 1) begin
                        col_group_count[c_i] = col_group_count[c_i] +
                            {{(POLICY_CNT_W-1){1'b0}}, (a_mask_i[r_i*K_BITS + k_i] &&
                                                        b_mask_i[c_i*K_BITS + k_i])};
                    end
                end
            end

            active_b_cols_o = {{(ACTIVE_COLS_W-1){1'b0}}, 1'b1};
            overflow_o = (col_group_count[0] > LANES);
            for (c_i = 0; c_i < NUM_COLS; c_i = c_i + 1) begin
                if (col_group_count[c_i] <= LANES) begin
                    active_b_cols_o = c_i + 1;
                    overflow_o = 1'b0;
                end
            end

            for (r_i = 0; r_i < NUM_ROWS; r_i = r_i + 1) begin
                for (c_i = 0; c_i < NUM_COLS; c_i = c_i + 1) begin
                    for (k_i = 0; k_i < K_BITS; k_i = k_i + 1) begin
                        e_i = r_i * NUM_COLS * K_BITS + c_i * K_BITS + k_i;
                        event_valid[e_i] = a_mask_i[r_i*K_BITS + k_i] &&
                                           b_mask_i[c_i*K_BITS + k_i] &&
                                           (c_i < active_b_cols_o);
                    end
                end
            end

            for (e_i = 0; e_i < TOTAL_CANDIDATES; e_i = e_i + 1) begin
                event_rank[e_i] = {POLICY_CNT_W{1'b0}};
                for (p_i = 0; p_i <= e_i; p_i = p_i + 1)
                    event_rank[e_i] = event_rank[e_i] + {{(POLICY_CNT_W-1){1'b0}}, event_valid[p_i]};
            end

            match_count_o = event_rank[TOTAL_CANDIDATES-1][CNT_W-1:0];

            for (l_i = 0; l_i < LANES; l_i = l_i + 1) begin
                for (e_i = 0; e_i < TOTAL_CANDIDATES; e_i = e_i + 1) begin
                    if (event_valid[e_i] && (event_rank[e_i] == (l_i + 1))) begin
                        ev_r = e_i / (NUM_COLS * K_BITS);
                        ev_c = (e_i / K_BITS) % NUM_COLS;
                        ev_k = e_i % K_BITS;
                        lane_valid_o[l_i] = 1'b1;
                        a_row_sel_o[l_i*ROW_IDX_W +: ROW_IDX_W] = ev_r[ROW_IDX_W-1:0];
                        b_col_sel_o[l_i*COL_IDX_W +: COL_IDX_W] = ev_c[COL_IDX_W-1:0];
                        k_sel_o[l_i*K_IDX_W +: K_IDX_W] = ev_k[K_IDX_W-1:0];
                    end
                end
            end
        end else begin
            active_b_cols_o = NUM_COLS;
            for (l_i = 0; l_i < LANES; l_i = l_i + 1) begin
                ev_r = l_i / (NUM_COLS * K_BITS);
                ev_c = (l_i / K_BITS) % NUM_COLS;
                ev_k = l_i % K_BITS;
                if (l_i < TOTAL_CANDIDATES) begin
                    lane_valid_o[l_i] = a_mask_i[ev_r*K_BITS + ev_k] &&
                                        b_mask_i[ev_c*K_BITS + ev_k];
                    a_row_sel_o[l_i*ROW_IDX_W +: ROW_IDX_W] = ev_r[ROW_IDX_W-1:0];
                    b_col_sel_o[l_i*COL_IDX_W +: COL_IDX_W] = ev_c[COL_IDX_W-1:0];
                    k_sel_o[l_i*K_IDX_W +: K_IDX_W] = ev_k[K_IDX_W-1:0];
                    match_count_o = match_count_o + {{(CNT_W-1){1'b0}}, lane_valid_o[l_i]};
                end
            end
        end
    end

endmodule
