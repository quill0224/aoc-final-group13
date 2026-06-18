// Pipelined packed Multi-Fiber Intersection Unit.
//
// 5-stage pipeline — per-stage critical chain:
//   s1  (0→1): capture A/B masks
//   s2a (1→2): per-(col,row) AND-popcount       chain = K_BITS, 16 pairs parallel
//   s2b (2→3): col prefix + active_b_cols + bitmap  chain = NUM_ROWS + 2×NUM_COLS
//   s3  (3→4): per-group local prefix sum        chain = G_SIZE = TOTAL/GROUPS
//   s4  (4→5): group base (chain GROUPS) + gather (comb OR tree, depth=log2(TC))
//
// Improvement vs original single-stage:
//   original: 512-chain in pack loop (stage 3) AND 512-chain col_grp_cnt (stage 2)
//   now: max per-stage chain = G_SIZE = 64 (for 4×4×32/GROUPS=8)
//   scatter→gather: variable-indexed NB write in always @(clk) creates TC-deep mux
//   chain via Yosys proc; gather in always @* yields log2(TC)-deep OR tree instead
//
// Constraint: TOTAL_CANDIDATES must be divisible by GROUPS.

module mfiu_pipelined #(
    parameter NUM_ROWS      = 2,
    parameter NUM_COLS      = 2,
    parameter K_BITS        = 4,
    parameter LANES         = 16,
    parameter GROUPS        = 8,
    parameter ROW_IDX_W     = (NUM_ROWS > 1) ? $clog2(NUM_ROWS) : 1,
    parameter COL_IDX_W     = (NUM_COLS > 1) ? $clog2(NUM_COLS) : 1,
    parameter K_IDX_W       = (K_BITS   > 1) ? $clog2(K_BITS)   : 1,
    parameter ACTIVE_COLS_W = (NUM_COLS > 1) ? $clog2(NUM_COLS + 1) : 1,
    parameter CNT_W         = $clog2(LANES + 1),
    parameter TOTAL_CANDIDATES = NUM_ROWS * NUM_COLS * K_BITS,
    parameter EVENT_CNT_W   = $clog2(TOTAL_CANDIDATES + 1),
    parameter G_SIZE        = TOTAL_CANDIDATES / GROUPS,
    parameter G_CNT_W       = $clog2(G_SIZE + 1),
    parameter POLICY_CNT_W  = $clog2(TOTAL_CANDIDATES + 1),
    parameter PAIR_CNT_W    = $clog2(K_BITS + 1)
) (
    input  wire                          clk,
    input  wire                          reset,
    input  wire                          valid_i,
    input  wire [EVENT_CNT_W-1:0]        replay_skip_i,
    input  wire [NUM_ROWS*K_BITS-1:0]   a_mask_i,
    input  wire [NUM_COLS*K_BITS-1:0]   b_mask_i,

    output reg                           valid_o,
    output reg  [LANES-1:0]             lane_valid_o,
    output reg  [LANES*ROW_IDX_W-1:0]  a_row_sel_o,
    output reg  [LANES*COL_IDX_W-1:0]  b_col_sel_o,
    output reg  [LANES*K_IDX_W-1:0]    k_sel_o,
    output reg  [CNT_W-1:0]            match_count_o,
    output reg  [ACTIVE_COLS_W-1:0]    active_b_cols_o,
    output reg                           overflow_o
);

    // ── Stage 1: register input masks ────────────────────────────────────────
    reg [NUM_ROWS*K_BITS-1:0] a_mask_r;
    reg [NUM_COLS*K_BITS-1:0] b_mask_r;
    reg [EVENT_CNT_W-1:0] replay_skip_r;
    reg s1_valid;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            a_mask_r <= {(NUM_ROWS*K_BITS){1'b0}};
            b_mask_r <= {(NUM_COLS*K_BITS){1'b0}};
            replay_skip_r <= {EVENT_CNT_W{1'b0}};
            s1_valid <= 1'b0;
        end else begin
            s1_valid <= valid_i;
            if (valid_i) begin
                a_mask_r <= a_mask_i;
                b_mask_r <= b_mask_i;
                replay_skip_r <= replay_skip_i;
            end
        end
    end

    // ── Stage 2a: per-(col,row) AND-popcount ──────────────────────────────────
    // Each of NUM_COLS×NUM_ROWS pairs independently counts how many k positions
    // have a_mask[r][k] & b_mask[c][k] = 1.  Chain = K_BITS; all pairs parallel.
    reg [PAIR_CNT_W-1:0] pair_cnt_next [0:NUM_COLS*NUM_ROWS-1];  // [c*NUM_ROWS+r]
    reg [PAIR_CNT_W-1:0] pair_cnt_r    [0:NUM_COLS*NUM_ROWS-1];
    reg [NUM_ROWS*K_BITS-1:0] a_mask_r2;   // forward masks to stage 2b
    reg [NUM_COLS*K_BITS-1:0] b_mask_r2;
    reg [EVENT_CNT_W-1:0] replay_skip_r2;
    reg s2a_valid;

    integer s2a_c, s2a_r, s2a_k, s2a_i;

    always @* begin
        for (s2a_c = 0; s2a_c < NUM_COLS; s2a_c = s2a_c + 1)
            for (s2a_r = 0; s2a_r < NUM_ROWS; s2a_r = s2a_r + 1) begin
                pair_cnt_next[s2a_c*NUM_ROWS + s2a_r] = {PAIR_CNT_W{1'b0}};
                for (s2a_k = 0; s2a_k < K_BITS; s2a_k = s2a_k + 1)
                    pair_cnt_next[s2a_c*NUM_ROWS + s2a_r] =
                        pair_cnt_next[s2a_c*NUM_ROWS + s2a_r] +
                        {{(PAIR_CNT_W-1){1'b0}},
                         (a_mask_r[s2a_r*K_BITS + s2a_k] & b_mask_r[s2a_c*K_BITS + s2a_k])};
            end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            s2a_valid <= 1'b0;
            a_mask_r2 <= {(NUM_ROWS*K_BITS){1'b0}};
            b_mask_r2 <= {(NUM_COLS*K_BITS){1'b0}};
            replay_skip_r2 <= {EVENT_CNT_W{1'b0}};
            for (s2a_i = 0; s2a_i < NUM_COLS*NUM_ROWS; s2a_i = s2a_i + 1)
                pair_cnt_r[s2a_i] <= {PAIR_CNT_W{1'b0}};
        end else begin
            s2a_valid <= s1_valid;
            a_mask_r2 <= a_mask_r;
            b_mask_r2 <= b_mask_r;
            replay_skip_r2 <= replay_skip_r;
            for (s2a_i = 0; s2a_i < NUM_COLS*NUM_ROWS; s2a_i = s2a_i + 1)
                pair_cnt_r[s2a_i] <= pair_cnt_next[s2a_i];
        end
    end

    // ── Stage 2b: column prefix + active_b_cols + event_valid bitmap ─────────
    // Chain = (NUM_ROWS-1) col_cnt adds + (NUM_COLS-1) col_acc adds
    //       + NUM_COLS comparisons + 2 ANDs for event_valid
    // For 4×4: 3+3+4+2 ≈ 12 gate levels (vs old 512-chain col_grp_cnt).
    reg [TOTAL_CANDIDATES-1:0] event_valid_r;
    reg [POLICY_CNT_W-1:0]    event_count_r;
    reg [EVENT_CNT_W-1:0]     replay_skip_r3;
    reg [ACTIVE_COLS_W-1:0]   active_b_cols_r;
    reg                         overflow_r;
    reg s2b_valid;

    reg [POLICY_CNT_W-1:0] col_cnt [0:NUM_COLS-1];
    reg [POLICY_CNT_W-1:0] col_acc [0:NUM_COLS-1];
    reg [TOTAL_CANDIDATES-1:0] ev_next2;
    reg [POLICY_CNT_W-1:0]    ec_next2;
    reg [ACTIVE_COLS_W-1:0]   ac_next2;
    reg                         ov_next2;

    integer s2b_c, s2b_r, s2b_k, s2b_e;

    always @* begin
        ev_next2 = {TOTAL_CANDIDATES{1'b0}};
        ac_next2 = 1;
        ov_next2 = 1'b0;

        // Step 1: per-column event count (chain = NUM_ROWS-1 adds, cols parallel)
        for (s2b_c = 0; s2b_c < NUM_COLS; s2b_c = s2b_c + 1) begin
            col_cnt[s2b_c] = {POLICY_CNT_W{1'b0}};
            for (s2b_r = 0; s2b_r < NUM_ROWS; s2b_r = s2b_r + 1)
                col_cnt[s2b_c] = col_cnt[s2b_c] +
                    {{(POLICY_CNT_W-PAIR_CNT_W){1'b0}}, pair_cnt_r[s2b_c*NUM_ROWS + s2b_r]};
        end

        // Step 2: cumulative prefix across columns (chain = NUM_COLS-1 adds)
        col_acc[0] = col_cnt[0];
        for (s2b_c = 1; s2b_c < NUM_COLS; s2b_c = s2b_c + 1)
            col_acc[s2b_c] = col_acc[s2b_c-1] + col_cnt[s2b_c];

        // Step 3: find active_b_cols for policy visibility, while replay
        // uses the full column event stream so later B columns are not dropped.
        ec_next2 = col_acc[NUM_COLS-1];
        ov_next2 = (col_acc[0] > LANES);
        for (s2b_c = 0; s2b_c < NUM_COLS; s2b_c = s2b_c + 1)
            if (col_acc[s2b_c] <= LANES) begin
                ac_next2 = s2b_c + 1;
                ov_next2 = 1'b0;
            end

        // Step 4: event_valid bitmap across all columns; replay_skip_i selects
        // which LANES-wide window is emitted in the final gather stage.
        for (s2b_r = 0; s2b_r < NUM_ROWS; s2b_r = s2b_r + 1)
            for (s2b_c = 0; s2b_c < NUM_COLS; s2b_c = s2b_c + 1)
                for (s2b_k = 0; s2b_k < K_BITS; s2b_k = s2b_k + 1) begin
                    s2b_e = s2b_r * NUM_COLS * K_BITS + s2b_c * K_BITS + s2b_k;
                    ev_next2[s2b_e] = a_mask_r2[s2b_r*K_BITS + s2b_k] &
                                      b_mask_r2[s2b_c*K_BITS + s2b_k];
                end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            event_valid_r   <= {TOTAL_CANDIDATES{1'b0}};
            event_count_r   <= {POLICY_CNT_W{1'b0}};
            replay_skip_r3  <= {EVENT_CNT_W{1'b0}};
            active_b_cols_r <= {ACTIVE_COLS_W{1'b0}};
            overflow_r      <= 1'b0;
            s2b_valid       <= 1'b0;
        end else begin
            s2b_valid       <= s2a_valid;
            event_valid_r   <= ev_next2;
            event_count_r   <= ec_next2;
            replay_skip_r3  <= replay_skip_r2;
            active_b_cols_r <= ac_next2;
            overflow_r      <= ov_next2;
        end
    end

    // ── Stage 3: per-group local prefix sum ───────────────────────────────────
    // GROUPS independent chains of G_SIZE.  For 4×4×32/GROUPS=8: 8×64.
    reg [TOTAL_CANDIDATES-1:0] event_valid_r2;
    reg [G_CNT_W-1:0]          local_rank_r  [0:TOTAL_CANDIDATES-1];
    reg [G_CNT_W-1:0]          group_count_r [0:GROUPS-1];
    reg [POLICY_CNT_W-1:0]     event_count_r2;
    reg [EVENT_CNT_W-1:0]      replay_skip_r4;
    reg [ACTIVE_COLS_W-1:0]    active_b_cols_r2;
    reg                          overflow_r2;
    reg s3_valid;

    integer s3_g, s3_gi, s3_gbase, s3_lcnt;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            event_valid_r2   <= {TOTAL_CANDIDATES{1'b0}};
            event_count_r2   <= {POLICY_CNT_W{1'b0}};
            replay_skip_r4   <= {EVENT_CNT_W{1'b0}};
            active_b_cols_r2 <= {ACTIVE_COLS_W{1'b0}};
            overflow_r2      <= 1'b0;
            s3_valid         <= 1'b0;
            for (s3_g = 0; s3_g < GROUPS; s3_g = s3_g + 1)
                group_count_r[s3_g] <= {G_CNT_W{1'b0}};
            for (s3_gi = 0; s3_gi < TOTAL_CANDIDATES; s3_gi = s3_gi + 1)
                local_rank_r[s3_gi] <= {G_CNT_W{1'b0}};
        end else begin
            s3_valid         <= s2b_valid;
            event_valid_r2   <= event_valid_r;
            event_count_r2   <= event_count_r;
            replay_skip_r4   <= replay_skip_r3;
            active_b_cols_r2 <= active_b_cols_r;
            overflow_r2      <= overflow_r;
            for (s3_g = 0; s3_g < GROUPS; s3_g = s3_g + 1) begin
                s3_gbase = s3_g * G_SIZE;
                s3_lcnt  = 0;
                for (s3_gi = 0; s3_gi < G_SIZE; s3_gi = s3_gi + 1) begin
                    if (event_valid_r[s3_gbase + s3_gi]) begin
                        local_rank_r[s3_gbase + s3_gi] <= s3_lcnt[G_CNT_W-1:0];
                        s3_lcnt = s3_lcnt + 1;
                    end else
                        local_rank_r[s3_gbase + s3_gi] <= {G_CNT_W{1'b0}};
                end
                group_count_r[s3_g] <= s3_lcnt[G_CNT_W-1:0];
            end
        end
    end

    // ── Stage 4: group base (comb) + gather (comb OR tree) + register ────────
    // gather in always @* lets Yosys build an OR tree (depth=log2(TC)) instead
    // of the TC-deep mux priority chain that scatter in always @(posedge clk)
    // creates via the proc pass.
    reg [EVENT_CNT_W-1:0]     s4_gbase       [0:GROUPS-1];
    reg [LANES-1:0]           lane_valid_next;
    reg [LANES*ROW_IDX_W-1:0] a_row_sel_next;
    reg [LANES*COL_IDX_W-1:0] b_col_sel_next;
    reg [LANES*K_IDX_W-1:0]   k_sel_next;
    reg [CNT_W-1:0]           emitted_count_next;
    reg                       overflow_next;

    integer s4_gb, s4_e, s4_gidx, s4_lidx, s4_evr, s4_evc, s4_evk;
    integer s4_global_rank;
    integer s4_replay_lane;

    always @* begin
        // Group base prefix sum (chain = GROUPS additions)
        s4_gbase[0] = {CNT_W{1'b0}};
        for (s4_gb = 1; s4_gb < GROUPS; s4_gb = s4_gb + 1)
            s4_gbase[s4_gb] = s4_gbase[s4_gb-1] + group_count_r[s4_gb-1];

        // Gather: for each event compute its lane, then OR-reduce per lane
        lane_valid_next = {LANES{1'b0}};
        a_row_sel_next  = {(LANES*ROW_IDX_W){1'b0}};
        b_col_sel_next  = {(LANES*COL_IDX_W){1'b0}};
        k_sel_next      = {(LANES*K_IDX_W){1'b0}};
        emitted_count_next = {CNT_W{1'b0}};
        overflow_next = (event_count_r2 > replay_skip_r4 + LANES);
        s4_gidx = 0;
        s4_lidx = 0;
        s4_global_rank = 0;
        s4_replay_lane = 0;
        s4_evr = 0;
        s4_evc = 0;
        s4_evk = 0;
        for (s4_e = 0; s4_e < TOTAL_CANDIDATES; s4_e = s4_e + 1) begin
            if (event_valid_r2[s4_e]) begin
                s4_gidx = s4_e / G_SIZE;
                s4_lidx = s4_gbase[s4_gidx] + local_rank_r[s4_e];
                s4_global_rank = s4_lidx;
                s4_replay_lane = s4_global_rank - replay_skip_r4;
                if ((s4_global_rank >= replay_skip_r4) && (s4_replay_lane < LANES)) begin
                    s4_evr = s4_e / (NUM_COLS * K_BITS);
                    s4_evc = (s4_e / K_BITS) % NUM_COLS;
                    s4_evk = s4_e % K_BITS;
                    lane_valid_next[s4_replay_lane] = 1'b1;
                    a_row_sel_next [s4_replay_lane*ROW_IDX_W +: ROW_IDX_W] = s4_evr[ROW_IDX_W-1:0];
                    b_col_sel_next [s4_replay_lane*COL_IDX_W +: COL_IDX_W] = s4_evc[COL_IDX_W-1:0];
                    k_sel_next     [s4_replay_lane*K_IDX_W   +: K_IDX_W  ] = s4_evk[K_IDX_W-1:0];
                    emitted_count_next = emitted_count_next + {{(CNT_W-1){1'b0}}, 1'b1};
                end
            end
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            valid_o         <= 1'b0;
            lane_valid_o    <= {LANES{1'b0}};
            a_row_sel_o     <= {(LANES*ROW_IDX_W){1'b0}};
            b_col_sel_o     <= {(LANES*COL_IDX_W){1'b0}};
            k_sel_o         <= {(LANES*K_IDX_W){1'b0}};
            match_count_o   <= {CNT_W{1'b0}};
            active_b_cols_o <= {ACTIVE_COLS_W{1'b0}};
            overflow_o      <= 1'b0;
        end else begin
            valid_o         <= s3_valid;
            match_count_o   <= emitted_count_next;
            active_b_cols_o <= active_b_cols_r2;
            overflow_o      <= overflow_next;
            lane_valid_o    <= lane_valid_next;
            a_row_sel_o     <= a_row_sel_next;
            b_col_sel_o     <= b_col_sel_next;
            k_sel_o         <= k_sel_next;
        end
    end

endmodule
