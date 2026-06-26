// =============================================================================
// mfiu.sv - multi-fiber intersection unit
// =============================================================================
// Intersects one A bitmask with up to N_B_FIBER B bitmasks. Consecutive B
// columns are packed while their total intersection count fits in N_MUL_ROW
// lanes.
//
// This implementation intentionally uses a small sequential COUNT/FILL FSM
// instead of producing every packed metadata lane in one combinational cycle.
// The external contract is unchanged: metadata is valid for one cycle when
// meta_valid is asserted. The latency from b_in_valid to meta_valid is variable.
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
        COUNT_COL,
        DECIDE_COL,
        FILL_COL,
        OUT
    } state_t;

    localparam int COL_IDX_W = (N_B_FIBER > 1) ? $clog2(N_B_FIBER + 1) : 1;
    localparam int K_IDX_W   = (N_MUL_ROW > 1) ? $clog2(N_MUL_ROW) : 1;
    localparam int COUNT_W   = $clog2(N_MUL_ROW + 1);

    state_t state_q;

    logic                                a_last_q;
    logic                                b_group_last_q;
    logic [N_MUL_ROW-1:0]                a_bitmask_q;
    logic [N_B_FIBER-1:0][N_MUL_ROW-1:0] b_bitmask_q;
    logic [COL_IDX_W-1:0]                valid_b_cols_q;
    logic [COL_IDX_W-1:0]                col_idx_q;
    logic [COL_IDX_W-1:0]                used_cols_q;
    logic [K_IDX_W-1:0]                  k_idx_q;

    logic [COUNT_W-1:0]                  candidate_count_q;
    logic [COUNT_W-1:0]                  col_count_q;
    logic [COUNT_W-1:0]                  lane_count_q;
    logic [COUNT_W-1:0]                  a_prefix_q;
    logic [COUNT_W-1:0]                  b_prefix_q;

    wire current_hit = a_bitmask_q[k_idx_q] & b_bitmask_q[col_idx_q][k_idx_q];
    wire [COUNT_W-1:0] col_count_next = col_count_q + COUNT_W'(current_hit);
    wire [COUNT_W:0] candidate_plus_col =
        {1'b0, candidate_count_q} + {1'b0, col_count_q};
    wire col_fits = (candidate_plus_col <= (COUNT_W+1)'(N_MUL_ROW));
    wire count_last_k = (k_idx_q == K_IDX_W'(N_MUL_ROW - 1));
    wire fill_last_k = count_last_k;
    wire [COL_IDX_W-1:0] next_col_idx = col_idx_q + COL_IDX_W'(1);
    wire more_valid_cols = (next_col_idx < valid_b_cols_q);
    wire consumed_all_offered = (used_cols_q >= valid_b_cols_q);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= IDLE;
            a_last_q <= 1'b0;
            b_group_last_q <= 1'b0;
            a_bitmask_q <= '0;
            b_bitmask_q <= '0;
            valid_b_cols_q <= '0;
            col_idx_q <= '0;
            used_cols_q <= '0;
            k_idx_q <= '0;
            candidate_count_q <= '0;
            col_count_q <= '0;
            lane_count_q <= '0;
            a_prefix_q <= '0;
            b_prefix_q <= '0;
            effectual_count <= '0;
            a_meta_data <= '0;
            b_meta_data <= '0;
            b_utilization <= '0;
            meta_valid <= 1'b0;
        end else begin
            meta_valid <= 1'b0;

            unique case (state_q)
                IDLE: begin
                    if (en && mode) begin
                        state_q <= LOAD_A;
                    end
                end

                LOAD_A: begin
                    if (a_in_valid) begin
                        a_bitmask_q <= a_bitmask;
                        state_q <= WAIT_B;
                    end
                end

                WAIT_B: begin
                    if (b_in_valid) begin
                        b_bitmask_q <= b_bitmask;
                        valid_b_cols_q <= COL_IDX_W'(b_col_valid) + COL_IDX_W'(1);
                        b_group_last_q <= b_group_last;
                        a_last_q <= a_last;
                        col_idx_q <= '0;
                        used_cols_q <= '0;
                        k_idx_q <= '0;
                        candidate_count_q <= '0;
                        col_count_q <= '0;
                        lane_count_q <= '0;
                        a_prefix_q <= '0;
                        b_prefix_q <= '0;
                        effectual_count <= '0;
                        b_utilization <= '0;
                        a_meta_data <= '0;
                        b_meta_data <= '0;
                        state_q <= COUNT_COL;
                    end
                end

                COUNT_COL: begin
                    col_count_q <= col_count_next;
                    if (count_last_k) begin
                        state_q <= DECIDE_COL;
                    end else begin
                        k_idx_q <= k_idx_q + K_IDX_W'(1);
                    end
                end

                DECIDE_COL: begin
                    if (col_fits) begin
                        candidate_count_q <= COUNT_W'(candidate_plus_col[COUNT_W-1:0]);
                        used_cols_q <= col_idx_q + COL_IDX_W'(1);
                        k_idx_q <= '0;
                        a_prefix_q <= '0;
                        b_prefix_q <= '0;
                        state_q <= FILL_COL;
                    end else begin
                        state_q <= OUT;
                    end
                end

                FILL_COL: begin
                    if (current_hit && (lane_count_q < COUNT_W'(N_MUL_ROW))) begin
                        a_meta_data[lane_count_q] <= 4'(a_prefix_q);
                        b_meta_data[lane_count_q][5:4] <= 2'(col_idx_q);
                        b_meta_data[lane_count_q][3:0] <= 4'(b_prefix_q);
                        lane_count_q <= lane_count_q + COUNT_W'(1);
                    end

                    if (a_bitmask_q[k_idx_q]) begin
                        a_prefix_q <= a_prefix_q + COUNT_W'(1);
                    end
                    if (b_bitmask_q[col_idx_q][k_idx_q]) begin
                        b_prefix_q <= b_prefix_q + COUNT_W'(1);
                    end

                    if (fill_last_k) begin
                        if (more_valid_cols) begin
                            col_idx_q <= next_col_idx;
                            k_idx_q <= '0;
                            col_count_q <= '0;
                            state_q <= COUNT_COL;
                        end else begin
                            state_q <= OUT;
                        end
                    end else begin
                        k_idx_q <= k_idx_q + K_IDX_W'(1);
                    end
                end

                OUT: begin
                    effectual_count <= lane_count_q;
                    b_utilization <= $bits(b_utilization)'(used_cols_q - COL_IDX_W'(1));
                    meta_valid <= 1'b1;

                    if (!consumed_all_offered) begin
                        state_q <= WAIT_B;
                    end else if (a_last_q) begin
                        state_q <= IDLE;
                    end else if (b_group_last_q) begin
                        state_q <= LOAD_A;
                    end else begin
                        state_q <= WAIT_B;
                    end
                end

                default: begin
                    state_q <= IDLE;
                end
            endcase
        end
    end

endmodule
