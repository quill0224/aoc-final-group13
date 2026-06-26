// =============================================================================
// pe_mfiu_seq.sv - per-row MFIU sequencer
// =============================================================================
// Processes one A bitmask against 16 B-column bitmasks. Up to N_B_FIBER
// columns are offered per batch; the MFIU reports how many were consumed, and
// col_ptr advances by that amount.
//
// grp_base identifies the first tile column in the batch. b_meta[5:4] is
// relative to grp_base. a_last is asserted with the B batch that reaches the
// final tile column. StandardIP bypasses this path and returns done without
// producing metadata.
//
// This sequencer also gathers the actual A/B compressed values for each
// packed lane. That folds the old per-row crossbar into the MFIU batch logic,
// so B operands are selected from the active 1-4 column batch instead of from
// all 16 tile columns. The gathered lane outputs are registered to cut the
// metadata-to-operand critical path.
// =============================================================================

module pe_mfiu_seq
    import trapezoid_pkg::*;
#(
    parameter bit DEBUG_META = 1'b0
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       mode,       // 1=TrIP, 0=StandardIP
    input  logic                       start,      // one-cycle start pulse
    output logic                       done,       // one-cycle completion pulse

    input  logic [N_MUL_ROW-1:0]       a_bm_row,        // A fiber bitmask
    input  logic [16*N_MUL_ROW-1:0]    b_bm_flat,       // 16 B col bitmasks
    input  logic [16*8-1:0]            a_nz_row_flat,   // A compressed values
    input  logic [16*16*8-1:0]         b_nz_flat,       // 16 B compressed value fibers

    // Metadata for one consumed B batch
    output logic                       out_valid,
    output logic [LANE_COUNT_W-1:0]    out_effectual,
    output logic [N_MUL_ROW-1:0][3:0]  out_a_meta,
    output logic [N_MUL_ROW-1:0][5:0]  out_b_meta,
    output logic [3:0]                 out_grp_base,
    output logic [2:0]                 out_grp_ncol,

    // Gathered operands for pe_row_tail
    output logic [16*8-1:0]            out_a_val_flat,
    output logic [16*8-1:0]            out_b_val_flat,
    output logic [16*4-1:0]            out_lane_col_flat,
    output logic [16-1:0]              out_lane_valid_flat
);

    localparam int NB_COLS = 16;          // B cols per tile
    localparam int MAXG    = N_B_FIBER;   // 4 max cols / batch

    typedef enum logic [2:0] { S_IDLE, S_LOADA, S_SENDB, S_WAIT, S_DONE } st_t;
    st_t        state;
    logic [4:0] col_ptr;   // next B column, 0..16

    // Number of remaining columns offered to the MFIU, capped at MAXG.
    logic [2:0] valid_cols;
    always_comb begin
        if ((NB_COLS[4:0] - col_ptr) >= 5'd4) valid_cols = 3'd4;
        else                                  valid_cols = 3'(NB_COLS[4:0] - col_ptr);
    end
    // The offered batch reaches the final tile column.
    wire is_last_batch = ((col_ptr + {2'b0, valid_cols}) >= NB_COLS[4:0]);

    // Gather the current B bitmask and compressed-value batch.
    logic [N_MUL_ROW-1:0] b_batch [0:MAXG-1];
    logic [16*8-1:0]      b_nz_batch [0:MAXG-1];
    logic [4:0] b_idx5;
    logic [3:0] b_idx4;
    integer bj;
    always_comb begin
        for (bj = 0; bj < MAXG; bj = bj + 1) begin
            b_idx5 = col_ptr + 5'(bj);
            b_idx4 = b_idx5[3:0];
            if ((bj < valid_cols) && (b_idx5 < NB_COLS[4:0])) begin
                b_batch[bj]    = b_bm_flat[b_idx4*N_MUL_ROW +: N_MUL_ROW];
                b_nz_batch[bj] = b_nz_flat[b_idx4*16*8 +: 16*8];
            end else begin
                b_batch[bj]    = '0;
                b_nz_batch[bj] = '0;
            end
        end
    end

    // Flatten b_nz_batch for mfiu's gather inputs.
    logic [N_B_FIBER*N_MUL_ROW*8-1:0] b_nz_batch_flat;
    genvar bfj;
    generate
        for (bfj = 0; bfj < N_B_FIBER; bfj = bfj + 1) begin : g_bnz_flat
            assign b_nz_batch_flat[bfj*N_MUL_ROW*8 +: N_MUL_ROW*8] = b_nz_batch[bfj];
        end
    endgenerate

    // MFIU interface
    logic                                  mfiu_a_in_valid, mfiu_b_in_valid, mfiu_a_last;
    logic [N_B_FIBER-1:0][N_MUL_ROW-1:0]   mfiu_b_bitmask;
    logic [$clog2(N_B_FIBER)-1:0]          mfiu_b_col_valid;
    logic [LANE_COUNT_W-1:0]               mfiu_effectual;
    logic [N_MUL_ROW-1:0][3:0]             mfiu_a_meta;
    logic [N_MUL_ROW-1:0][5:0]             mfiu_b_meta;
    logic [$clog2(N_B_FIBER)-1:0]          mfiu_b_util;
    logic                                  mfiu_meta_valid;
    logic [N_MUL_ROW*8-1:0]               mfiu_a_lane_data;
    logic [N_MUL_ROW*8-1:0]               mfiu_b_lane_data;
    logic [N_MUL_ROW*4-1:0]               mfiu_lane_col;
    logic [N_MUL_ROW-1:0]                 mfiu_lane_valid;

    genvar gj;
    generate
        for (gj = 0; gj < N_B_FIBER; gj = gj + 1) begin : g_bpack
            assign mfiu_b_bitmask[gj] = b_batch[gj];
        end
    endgenerate

    assign mfiu_a_in_valid  = (state == S_LOADA);
    assign mfiu_b_in_valid  = (state == S_SENDB);
    assign mfiu_a_last      = (state == S_SENDB) && is_last_batch;
    assign mfiu_b_col_valid = 2'(valid_cols - 3'd1);                 // count minus one

    mfiu u_mfiu (
        .clk(clk), .rst_n(rst_n),
        .en(mode), .mode(mode),
        .a_in_valid(mfiu_a_in_valid), .b_in_valid(mfiu_b_in_valid),
        .a_last(mfiu_a_last), .b_group_last(1'b0),
        .a_bitmask(a_bm_row), .b_bitmask(mfiu_b_bitmask), .b_col_valid(mfiu_b_col_valid),
        .effectual_count(mfiu_effectual), .a_meta_data(mfiu_a_meta),
        .b_meta_data(mfiu_b_meta), .b_utilization(mfiu_b_util), .meta_valid(mfiu_meta_valid),
        .a_nz_row_i(a_nz_row_flat), .b_nz_batch_i(b_nz_batch_flat), .col_ptr_i(col_ptr[3:0]),
        .a_lane_data_o(mfiu_a_lane_data), .b_lane_data_o(mfiu_b_lane_data),
        .lane_col_o(mfiu_lane_col), .lane_valid_o(mfiu_lane_valid)
    );

    // Number of columns consumed by the MFIU.
    wire [2:0] used_cols = 3'(mfiu_b_util) + 3'd1;
    wire [4:0] next_ptr  = col_ptr + {2'b0, used_cols};

    // Sequencer
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; col_ptr <= 5'd0;
        end else begin
            unique case (state)
                S_IDLE: begin
                    col_ptr <= 5'd0;
                    if (start &&  mode) state <= S_LOADA;
                    else if (start)     state <= S_DONE;   // StandardIP bypass
                end
                S_LOADA: state <= S_SENDB;
                S_SENDB: state <= S_WAIT;
                S_WAIT:  if (mfiu_meta_valid) begin
                             col_ptr <= next_ptr;
                             if (next_ptr >= NB_COLS[4:0]) state <= S_DONE;
                             else                          state <= S_SENDB;
                         end
                S_DONE:  state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end

    assign done          = (state == S_DONE);

    // out_valid is registered to align with mfiu's registered lane data.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) out_valid <= 1'b0;
        else        out_valid <= mfiu_meta_valid;
    end

    assign out_a_val_flat      = mfiu_a_lane_data;
    assign out_b_val_flat      = mfiu_b_lane_data;
    assign out_lane_col_flat   = mfiu_lane_col;
    assign out_lane_valid_flat = mfiu_lane_valid;

    generate
        if (DEBUG_META) begin : g_debug_meta
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    out_effectual <= '0;
                    out_a_meta    <= '0;
                    out_b_meta    <= '0;
                    out_grp_base  <= '0;
                    out_grp_ncol  <= '0;
                end else begin
                    out_effectual <= mfiu_effectual;
                    out_a_meta    <= mfiu_a_meta;
                    out_b_meta    <= mfiu_b_meta;
                    out_grp_base  <= col_ptr[3:0];
                    out_grp_ncol  <= used_cols;
                end
            end
        end else begin : g_no_debug_meta
            assign out_effectual = '0;
            assign out_a_meta    = '0;
            assign out_b_meta    = '0;
            assign out_grp_base  = '0;
            assign out_grp_ncol  = '0;
        end
    endgenerate

endmodule
