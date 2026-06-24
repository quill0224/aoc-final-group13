// =============================================================================
// mfiu.sv - multi-fiber intersection unit
// =============================================================================
// Intersects one A bitmask with up to N_B_FIBER B bitmasks. Consecutive B
// columns are packed while their total intersection count fits in
// N_MUL_ROW lanes.
//
// For each active lane:
//   a_meta_data       compressed index within the A fiber
//   b_meta_data[5:4]  B-column index within the current batch
//   b_meta_data[3:0]  compressed index within that B fiber
//
// b_col_valid and b_utilization encode column count minus one. meta_valid is
// asserted for one cycle when the registered metadata is available.
// =============================================================================
module mfiu
    import trapezoid_pkg::*;
(
    input  logic                                   clk,
    input  logic                                   rst_n,
    input  logic                                   en,
    input  logic                                   mode,
    input  logic                                   a_in_valid,
    input  logic                                   b_in_valid,
    input  logic                                   a_last,
    input  logic                                   b_group_last,
    input  logic [N_MUL_ROW-1:0]                   a_bitmask,
    input  logic [N_B_FIBER-1:0][N_MUL_ROW-1:0]    b_bitmask,
    input  logic [$clog2(N_B_FIBER)-1:0]           b_col_valid,

    output logic [$clog2(N_MUL_ROW+1)-1:0]         effectual_count,
    output logic [N_MUL_ROW-1:0][3:0]              a_meta_data,
    output logic [N_MUL_ROW-1:0][5:0]              b_meta_data,
    output logic [$clog2(N_B_FIBER)-1:0]           b_utilization,
    output logic                                   meta_valid
);

    typedef enum logic [2:0] {
        IDLE,
        LOAD_A,
        WAIT_B,
        CAL,
        OUT
    } state_t;

    state_t state_q, state_d;

    logic                                a_last_q;
    logic                                b_group_last_q;
    logic                                complete_col;
    logic [N_MUL_ROW-1:0]                a_bitmask_q;
    logic [N_B_FIBER-1:0][N_MUL_ROW-1:0] b_bitmask_q;
    logic [$clog2(N_B_FIBER)-1:0]        b_col_valid_q;

    logic [$clog2(N_MUL_ROW+1)-1:0]      effectual_count_d;
    logic [$clog2(N_B_FIBER)-1:0]        b_utilization_d;
    logic [3:0]                          a_meta_data_d [0:N_MUL_ROW-1];
    logic [5:0]                          b_meta_data_d [0:N_MUL_ROW-1];
    logic [N_MUL_ROW-1:0][3:0]           a_meta_data_d_pack;
    logic [N_MUL_ROW-1:0][5:0]           b_meta_data_d_pack;

    integer j;
    integer k;
    integer a_prefix_count;
    integer b_prefix_count;
    integer lane_count;
    integer valid_b_cols;
    integer used_b_cols;
    integer candidate_count;
    integer col_intersection_count;
    integer clear_idx;
    logic   packing_done;

    assign complete_col = (b_utilization == b_col_valid_q);

    genvar pack_i;
    generate
        for (pack_i = 0; pack_i < N_MUL_ROW; pack_i = pack_i + 1) begin : gen_pack_meta
            assign a_meta_data_d_pack[pack_i] = a_meta_data_d[pack_i];
            assign b_meta_data_d_pack[pack_i] = b_meta_data_d[pack_i];
        end
    endgenerate

    always_comb begin
        state_d = state_q;

        unique case (state_q)
            IDLE: begin
                // StandardIP bypasses the MFIU.
                if (en && mode) begin
                    state_d = LOAD_A;
                end
            end

            LOAD_A: begin
                if (a_in_valid) begin
                    state_d = WAIT_B;
                end
            end

            WAIT_B: begin
                if (b_in_valid) begin
                    state_d = CAL;
                end
            end

            CAL: begin
                state_d = OUT;
            end

            OUT: begin
                if (!complete_col) begin
                    state_d = WAIT_B;
                end else if (a_last_q) begin
                    state_d = IDLE;
                end else if (b_group_last_q) begin
                    state_d = LOAD_A;
                end else begin
                    state_d = WAIT_B;
                end
            end

            default: begin
                state_d = IDLE;
            end
        endcase
    end

    always_comb begin
        effectual_count_d = '0;
        b_utilization_d = '0;
        a_prefix_count = 0;
        b_prefix_count = 0;
        lane_count = 0;
        valid_b_cols = 0;
        used_b_cols = 1;
        candidate_count = 0;
        col_intersection_count = 0;
        packing_done = 1'b0;

        for (clear_idx = 0; clear_idx < N_MUL_ROW; clear_idx = clear_idx + 1) begin
            a_meta_data_d[clear_idx] = '0;
            b_meta_data_d[clear_idx] = '0;
        end

        // Encoded column count: 0..3 represents 1..4 valid B columns.
        valid_b_cols = int'(b_col_valid_q) + 1;
        if (valid_b_cols > N_B_FIBER) begin
            valid_b_cols = N_B_FIBER;
        end

        // Select the longest B-column prefix that fits in the metadata lanes.
        used_b_cols = 0;
        candidate_count = 0;
        packing_done = 1'b0;
        for (j = 0; j < N_B_FIBER; j = j + 1) begin
            col_intersection_count = 0;
            if ((j < valid_b_cols) && !packing_done) begin
                for (k = 0; k < N_MUL_ROW; k = k + 1) begin
                    if (a_bitmask_q[k] && b_bitmask_q[j][k]) begin
                        col_intersection_count = col_intersection_count + 1;
                    end
                end

                if ((candidate_count + col_intersection_count) <= N_MUL_ROW) begin
                    candidate_count = candidate_count + col_intersection_count;
                    used_b_cols = j + 1;
                end else begin
                    packing_done = 1'b1;
                end
            end
        end
        if (used_b_cols == 0) begin
            used_b_cols = 1;
        end
        b_utilization_d = $bits(b_utilization_d)'(used_b_cols - 1);

        for (j = 0; j < N_B_FIBER; j = j + 1) begin
            if (j < used_b_cols) begin
                a_prefix_count = 0;
                b_prefix_count = 0;
                for (k = 0; k < N_MUL_ROW; k = k + 1) begin
                    if (a_bitmask_q[k] && b_bitmask_q[j][k] && (lane_count < N_MUL_ROW)) begin
                        // Metadata indices are zero-based positions in the
                        // compressed A and B value arrays.
                        a_meta_data_d[lane_count] = 4'(a_prefix_count);
                        b_meta_data_d[lane_count][5:4] = 2'(j);
                        b_meta_data_d[lane_count][3:0] = 4'(b_prefix_count);
                        lane_count = lane_count + 1;
                    end
                    if (a_bitmask_q[k]) begin
                        a_prefix_count = a_prefix_count + 1;
                    end
                    if (b_bitmask_q[j][k]) begin
                        b_prefix_count = b_prefix_count + 1;
                    end
                end
            end
        end

        effectual_count_d = $bits(effectual_count_d)'(lane_count);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= IDLE;
            a_last_q <= 1'b0;
            b_group_last_q <= 1'b0;
            a_bitmask_q <= '0;
            b_bitmask_q <= '0;
            b_col_valid_q <= '0;
            effectual_count <= '0;
            a_meta_data <= '0;
            b_meta_data <= '0;
            b_utilization <= '0;
            meta_valid <= 1'b0;
        end else begin
            state_q <= state_d;
            meta_valid <= (state_d == OUT);

            if ((state_q == LOAD_A) && a_in_valid) begin
                a_bitmask_q <= a_bitmask;
            end

            if ((state_q == WAIT_B) && b_in_valid) begin
                b_bitmask_q <= b_bitmask;
                b_col_valid_q <= b_col_valid;
                b_group_last_q <= b_group_last;
                a_last_q <= a_last;
            end

            if (state_q == CAL) begin
                effectual_count <= effectual_count_d;
                a_meta_data <= a_meta_data_d_pack;
                b_meta_data <= b_meta_data_d_pack;
                b_utilization <= b_utilization_d;
            end
        end
    end

endmodule
