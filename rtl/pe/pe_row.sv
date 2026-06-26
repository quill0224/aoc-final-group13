// =============================================================================
// pe_row.sv - one PE-row datapath
// =============================================================================
//   pe_mfiu_seq -> pe_row_tail
//
// Each row owns one A fiber and shares all 16 B fibers. done indicates that
// the sequencer has issued every B batch; pe_array adds a drain delay before
// reporting tile completion.
// =============================================================================

module pe_row
    import trapezoid_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,

    // Control
    input  logic                      mode,          // 1=TrIP
    input  logic                      start,         // = pe_ab_buffer.tile_ready(開始處理本 tile)
    output logic                      done,

    // A fiber for this row and B fibers shared by all rows
    input  logic [N_MUL_ROW-1:0]      a_bm_row,
    input  logic [16*N_MUL_ROW-1:0]   b_bm_flat,
    input  logic [16*8-1:0]           a_nz_row_flat,
    input  logic [16*16*8-1:0]        b_nz_flat,

    // Accumulation and dump control
    input  logic                      first_pass,
    input  logic [LOCAL_BUF_AW-1:0]   cur_n_base,
    input  logic                      dump_en,
    input  logic [LOCAL_BUF_AW-1:0]   dump_addr,

    // Dump output for this matrix row
    output logic                      c_valid,
    output logic signed [ACC_W-1:0]   c_out
);

    // pe_mfiu_seq -> pe_row_tail
    logic                      m_valid;
    logic [LANE_COUNT_W-1:0]   m_eff;
    logic [N_MUL_ROW-1:0][3:0] m_a_meta;
    logic [N_MUL_ROW-1:0][5:0] m_b_meta;
    logic [3:0]                m_grp_base;
    logic [2:0]                m_grp_ncol;

    // Gathered operands from pe_mfiu_seq.
    logic [16*8-1:0]          x_a_val_flat;
    logic [16*8-1:0]          x_b_val_flat;
    logic [16*4-1:0]          x_lane_col_flat;
    logic [16-1:0]            x_lane_valid_flat;
    logic                     x_valid;

    pe_mfiu_seq u_seq (
        .clk(clk), .rst_n(rst_n),
        .mode(mode), .start(start), .done(done),
        .a_bm_row(a_bm_row), .b_bm_flat(b_bm_flat),
        .a_nz_row_flat(a_nz_row_flat), .b_nz_flat(b_nz_flat),
        .out_valid(m_valid), .out_effectual(m_eff),
        .out_a_meta(m_a_meta), .out_b_meta(m_b_meta),
        .out_grp_base(m_grp_base), .out_grp_ncol(m_grp_ncol),
        .out_a_val_flat(x_a_val_flat),
        .out_b_val_flat(x_b_val_flat),
        .out_lane_col_flat(x_lane_col_flat),
        .out_lane_valid_flat(x_lane_valid_flat)
    );
    assign x_valid = m_valid;

    pe_row_tail u_tail (
        .clk(clk), .rst_n(rst_n),
        .in_valid(x_valid),
        .a_val_flat(x_a_val_flat), .b_val_flat(x_b_val_flat),
        .lane_col_flat(x_lane_col_flat), .lane_valid_flat(x_lane_valid_flat),
        .first_pass(first_pass), .cur_n_base(cur_n_base),
        .dump_en(dump_en), .dump_addr(dump_addr),
        .c_valid(c_valid), .c_out(c_out)
    );

    // Metadata remains available for debug; the datapath uses gathered values.
    wire _unused = &{1'b0, m_eff, m_a_meta, m_b_meta, m_grp_base, m_grp_ncol};

endmodule
