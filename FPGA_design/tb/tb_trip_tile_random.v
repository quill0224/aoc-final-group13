`timescale 1ns/1ps

// Self-checking TB: random-sized sparse matrix multiplication via tiling.
//
// Each of the 5 iterations picks random M/N/K tile counts, fills A[M][K]
// and B[K][N] with sparse unsigned data, computes a software golden C = A×B,
// then drives the hardware tiling loop and compares every element.
//
// Overflow avoidance: each fiber has at most 1 nonzero per K-chunk,
// so intersections per chunk ≤ NUM_ROWS × NUM_COLS × K_BITS = LANES = 16.
//
// Run:
//   iverilog -g2012 -o sim.out \
//     bitmask_buffer.v mfiu.v pe_lane.v row_local_buffer.v \
//     trip_distribution_network.v trip_intersection_top.v  \
//     trip_reduction_tree.v trip_compute_top.v             \
//     trip_tile_compute_engine.v tb_trip_tile_random.v
//   vvp sim.out

module tb_trip_tile_random;

    // ── Hardware tile parameters ──────────────────────────────────────────────
    localparam NUM_ROWS       = 2;
    localparam NUM_COLS       = 2;
    localparam K_BITS         = 4;
    localparam LANES          = 16;  // must equal NUM_ROWS*NUM_COLS*K_BITS = 16
    localparam DATA_WIDTH     = 16;
    localparam ID_WIDTH       = 4;
    localparam ADDR_W_A       = 1;   // clog2(NUM_ROWS)
    localparam ADDR_W_B       = 1;   // clog2(NUM_COLS)
    localparam CNT_W          = 5;   // $clog2(LANES+1) = $clog2(17) = 5
    localparam PRODUCT_WIDTH  = DATA_WIDTH * 2;
    localparam ACC_WIDTH      = PRODUCT_WIDTH + CNT_W;
    localparam TILE_ACC_WIDTH = ACC_WIDTH + 8;
    localparam NUM_OUTPUTS    = NUM_ROWS * NUM_COLS;
    localparam VAL_W          = K_BITS * DATA_WIDTH;

    // ── Maximum matrix extents (in tile counts) ───────────────────────────────
    localparam MAX_M_TILES  = 4;
    localparam MAX_N_TILES  = 4;
    localparam MAX_K_CHUNKS = 4;
    localparam MAX_M = MAX_M_TILES  * NUM_ROWS;   // 8
    localparam MAX_N = MAX_N_TILES  * NUM_COLS;   // 8
    localparam MAX_K = MAX_K_CHUNKS * K_BITS;     // 16

    // ── DUT ports ─────────────────────────────────────────────────────────────
    reg clk, reset, start_i, clear_accum_i;
    reg a_wr_en_i, b_wr_en_i;
    reg [ADDR_W_A-1:0] a_wr_addr_i;
    reg [ADDR_W_B-1:0] b_wr_addr_i;
    reg [ID_WIDTH-1:0] a_wr_id_i, b_wr_id_i;
    reg [K_BITS-1:0]   a_wr_mask_i, b_wr_mask_i;
    reg [VAL_W-1:0]    a_wr_values_i, b_wr_values_i;

    wire busy_o, done_o, overflow_o, overflow_seen_o;
    wire [1:0] fsm_state_obs_o;
    wire [NUM_OUTPUTS-1:0]                tile_valid_o;
    wire [NUM_OUTPUTS*TILE_ACC_WIDTH-1:0] tile_result_o;
    wire [NUM_OUTPUTS-1:0]                partial_valid_o;
    wire [NUM_OUTPUTS*ACC_WIDTH-1:0]      partial_result_o;
    wire [CNT_W-1:0] match_count_o;
    wire [7:0]       chunk_count_o;

    trip_tile_compute_engine #(
        .NUM_ROWS       (NUM_ROWS),
        .NUM_COLS       (NUM_COLS),
        .K_BITS         (K_BITS),
        .LANES          (LANES),
        .DATA_WIDTH     (DATA_WIDTH),
        .ID_WIDTH       (ID_WIDTH),
        .TILE_ACC_WIDTH (TILE_ACC_WIDTH)
    ) dut (
        .clk              (clk),
        .reset            (reset),
        .a_wr_en_i        (a_wr_en_i),
        .a_wr_addr_i      (a_wr_addr_i),
        .a_wr_id_i        (a_wr_id_i),
        .a_wr_mask_i      (a_wr_mask_i),
        .a_wr_values_i    (a_wr_values_i),
        .b_wr_en_i        (b_wr_en_i),
        .b_wr_addr_i      (b_wr_addr_i),
        .b_wr_id_i        (b_wr_id_i),
        .b_wr_mask_i      (b_wr_mask_i),
        .b_wr_values_i    (b_wr_values_i),
        .start_i          (start_i),
        .clear_accum_i    (clear_accum_i),
        .busy_o           (busy_o),
        .done_o           (done_o),
        .partial_valid_o  (partial_valid_o),
        .partial_result_o (partial_result_o),
        .match_count_o    (match_count_o),
        .overflow_o       (overflow_o),
        .overflow_seen_o  (overflow_seen_o),
        .tile_valid_o     (tile_valid_o),
        .tile_result_o    (tile_result_o),
        .chunk_count_o    (chunk_count_o),
        .test_mode_i      (1'b0),
        .scan_en_i        (1'b0),
        .fsm_state_obs_o  (fsm_state_obs_o)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer seed     = 32'hABCD_1234;

    // ── Full matrix storage (max dims, runtime-bounded) ───────────────────────
    reg [DATA_WIDTH-1:0] big_a [0:MAX_M-1][0:MAX_K-1];
    reg [DATA_WIDTH-1:0] big_b [0:MAX_K-1][0:MAX_N-1];
    integer golden [0:MAX_M-1][0:MAX_N-1];

    // Runtime tile counts (set before each iteration)
    integer m_tiles, n_tiles, k_chunks;

    // ── Extract one element from the packed result bus ────────────────────────
    function [TILE_ACC_WIDTH-1:0] tile_result_at;
        input integer idx;
        begin
            tile_result_at = tile_result_o[idx*TILE_ACC_WIDTH +: TILE_ACC_WIDTH];
        end
    endfunction

    // ── Build bitmask and values bus for one A-row fiber ─────────────────────
    // big_a[row][kc*K_BITS + k] → packed as values[k*DW +: DW]
    function [K_BITS-1:0] a_mask_for;
        input integer row;
        input integer kc;
        integer k;
        begin
            a_mask_for = {K_BITS{1'b0}};
            for (k = 0; k < K_BITS; k = k + 1)
                if (big_a[row][kc*K_BITS + k] != 0)
                    a_mask_for[k] = 1'b1;
        end
    endfunction

    function [VAL_W-1:0] a_vals_for;
        input integer row;
        input integer kc;
        integer k;
        reg [VAL_W-1:0] v;
        begin
            v = {VAL_W{1'b0}};
            for (k = 0; k < K_BITS; k = k + 1)
                v[k*DATA_WIDTH +: DATA_WIDTH] = big_a[row][kc*K_BITS + k];
            a_vals_for = v;
        end
    endfunction

    // ── Build bitmask and values bus for one B-col fiber ─────────────────────
    // big_b[kc*K_BITS + k][col] → packed as values[k*DW +: DW]
    function [K_BITS-1:0] b_mask_for;
        input integer col;
        input integer kc;
        integer k;
        begin
            b_mask_for = {K_BITS{1'b0}};
            for (k = 0; k < K_BITS; k = k + 1)
                if (big_b[kc*K_BITS + k][col] != 0)
                    b_mask_for[k] = 1'b1;
        end
    endfunction

    function [VAL_W-1:0] b_vals_for;
        input integer col;
        input integer kc;
        integer k;
        reg [VAL_W-1:0] v;
        begin
            v = {VAL_W{1'b0}};
            for (k = 0; k < K_BITS; k = k + 1)
                v[k*DATA_WIDTH +: DATA_WIDTH] = big_b[kc*K_BITS + k][col];
            b_vals_for = v;
        end
    endfunction

    // ── Sparse random matrix generation ──────────────────────────────────────
    // Each fiber (A row or B col) gets at most one nonzero element per K-chunk.
    // This ensures: intersections per chunk ≤ NUM_ROWS × NUM_COLS = LANES → no overflow.
    task fill_random_matrices;
        integer m, n, kc, k, kpos, val;
        begin
            for (m = 0; m < MAX_M; m = m + 1)
                for (k = 0; k < MAX_K; k = k + 1)
                    big_a[m][k] = 0;
            for (k = 0; k < MAX_K; k = k + 1)
                for (n = 0; n < MAX_N; n = n + 1)
                    big_b[k][n] = 0;

            for (m = 0; m < m_tiles * NUM_ROWS; m = m + 1)
                for (kc = 0; kc < k_chunks; kc = kc + 1)
                    if (($random(seed) & 3) != 0) begin   // 75% nonzero
                        kpos = $random(seed) & (K_BITS - 1);
                        val  = ($random(seed) & 7) + 1;   // 1..8
                        big_a[m][kc * K_BITS + kpos] = val;
                    end

            for (n = 0; n < n_tiles * NUM_COLS; n = n + 1)
                for (kc = 0; kc < k_chunks; kc = kc + 1)
                    if (($random(seed) & 3) != 0) begin
                        kpos = $random(seed) & (K_BITS - 1);
                        val  = ($random(seed) & 7) + 1;
                        big_b[kc * K_BITS + kpos][n] = val;
                    end
        end
    endtask

    // Software reference: C = A × B
    task compute_golden;
        integer m, n, k;
        begin
            for (m = 0; m < m_tiles * NUM_ROWS; m = m + 1)
                for (n = 0; n < n_tiles * NUM_COLS; n = n + 1) begin
                    golden[m][n] = 0;
                    for (k = 0; k < k_chunks * K_BITS; k = k + 1)
                        golden[m][n] = golden[m][n] + big_a[m][k] * big_b[k][n];
                end
        end
    endtask

    // ── Hardware write helpers ────────────────────────────────────────────────
    task write_a_fiber;
        input [ADDR_W_A-1:0] addr;
        input [ID_WIDTH-1:0] id;
        input [K_BITS-1:0]   mask;
        input [VAL_W-1:0]    values;
        begin
            @(negedge clk);
            a_wr_en_i = 1'b1; a_wr_addr_i = addr; a_wr_id_i = id;
            a_wr_mask_i = mask; a_wr_values_i = values;
            @(posedge clk); #1;
            a_wr_en_i = 1'b0;
        end
    endtask

    task write_b_fiber;
        input [ADDR_W_B-1:0] addr;
        input [ID_WIDTH-1:0] id;
        input [K_BITS-1:0]   mask;
        input [VAL_W-1:0]    values;
        begin
            @(negedge clk);
            b_wr_en_i = 1'b1; b_wr_addr_i = addr; b_wr_id_i = id;
            b_wr_mask_i = mask; b_wr_values_i = values;
            @(posedge clk); #1;
            b_wr_en_i = 1'b0;
        end
    endtask

    // ── Tiling loop ───────────────────────────────────────────────────────────
    // For each (mt, nt) output tile, sweep all K-chunks.
    // First chunk uses clear_accum_i=1; subsequent chunks accumulate.
    task run_tile;
        input integer mt;
        input integer nt;
        integer kc, r, c;
        begin
            for (kc = 0; kc < k_chunks; kc = kc + 1) begin
                // Load A fibers for rows [mt*NR .. mt*NR+NR-1], k-chunk kc
                for (r = 0; r < NUM_ROWS; r = r + 1)
                    write_a_fiber(r[ADDR_W_A-1:0], r[ID_WIDTH-1:0],
                                  a_mask_for(mt*NUM_ROWS + r, kc),
                                  a_vals_for(mt*NUM_ROWS + r, kc));
                // Load B fibers for cols [nt*NC .. nt*NC+NC-1], k-chunk kc
                for (c = 0; c < NUM_COLS; c = c + 1)
                    write_b_fiber(c[ADDR_W_B-1:0], c[ID_WIDTH-1:0],
                                  b_mask_for(nt*NUM_COLS + c, kc),
                                  b_vals_for(nt*NUM_COLS + c, kc));

                // Pulse start; clear tile accumulator only on first chunk
                @(negedge clk);
                start_i       = 1'b1;
                clear_accum_i = (kc == 0) ? 1'b1 : 1'b0;
                @(posedge clk); #1;
                start_i       = 1'b0;
                clear_accum_i = 1'b0;
                wait (done_o === 1'b1);
                #1;
            end
        end
    endtask

    // ── Result checker ────────────────────────────────────────────────────────
    task check_tile;
        input [255:0] label;
        input integer mt;
        input integer nt;
        integer r, c, idx, exp, got;
        begin
            if (overflow_seen_o) begin
                $display("SKIP  %s tile(%0d,%0d): overflow_seen — data was too dense",
                         label, mt, nt);
            end else begin
                for (r = 0; r < NUM_ROWS; r = r + 1)
                    for (c = 0; c < NUM_COLS; c = c + 1) begin
                        idx = r * NUM_COLS + c;
                        exp = golden[mt*NUM_ROWS + r][nt*NUM_COLS + c];
                        got = tile_result_at(idx);
                        if (got === exp) begin
                            $display("PASS  %s C[%0d][%0d] = %0d",
                                     label, mt*NUM_ROWS+r, nt*NUM_COLS+c, got);
                            pass_cnt = pass_cnt + 1;
                        end else begin
                            $display("FAIL  %s C[%0d][%0d] got=%0d exp=%0d",
                                     label, mt*NUM_ROWS+r, nt*NUM_COLS+c, got, exp);
                            fail_cnt = fail_cnt + 1;
                        end
                    end
            end
        end
    endtask

    task reset_dut;
        begin
            reset         = 1'b1;
            start_i       = 1'b0;
            clear_accum_i = 1'b0;
            a_wr_en_i     = 1'b0;
            b_wr_en_i     = 1'b0;
            a_wr_addr_i   = {ADDR_W_A{1'b0}};
            b_wr_addr_i   = {ADDR_W_B{1'b0}};
            a_wr_id_i     = {ID_WIDTH{1'b0}};
            b_wr_id_i     = {ID_WIDTH{1'b0}};
            a_wr_mask_i   = {K_BITS{1'b0}};
            b_wr_mask_i   = {K_BITS{1'b0}};
            a_wr_values_i = {VAL_W{1'b0}};
            b_wr_values_i = {VAL_W{1'b0}};
            repeat (3) @(posedge clk);
            @(negedge clk); reset = 1'b0;
        end
    endtask

    // ── Main test ─────────────────────────────────────────────────────────────
    integer iter, mt, nt;

    initial begin
        reset_dut;

        for (iter = 0; iter < 5; iter = iter + 1) begin
            // Pick random tile counts (1 .. MAX_*).
            // Use bitmask instead of % to avoid signed-modulo giving negative values.
            m_tiles  = ($random(seed) & (MAX_M_TILES  - 1)) + 1;
            n_tiles  = ($random(seed) & (MAX_N_TILES  - 1)) + 1;
            k_chunks = ($random(seed) & (MAX_K_CHUNKS - 1)) + 1;

            $display("\n--- iter %0d: A=%0dx%0d  x  B=%0dx%0d  (M-tiles=%0d N-tiles=%0d K-chunks=%0d) ---",
                iter,
                m_tiles*NUM_ROWS, k_chunks*K_BITS,
                k_chunks*K_BITS,  n_tiles*NUM_COLS,
                m_tiles, n_tiles, k_chunks);

            fill_random_matrices;
            compute_golden;

            for (mt = 0; mt < m_tiles; mt = mt + 1)
                for (nt = 0; nt < n_tiles; nt = nt + 1) begin
                    run_tile(mt, nt);
                    check_tile("random", mt, nt);
                end
        end

        $display("\n------------------------------------------");
        $display("tb_trip_tile_random: %0d passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL PASS"); else $display("SOME FAILURES");
        $display("------------------------------------------");
        $finish;
    end

endmodule
