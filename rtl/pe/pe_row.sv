// =============================================================================
// pe_row.sv - one PE-row datapath
// =============================================================================
//   pe_mfiu_seq -> crossbar -> pe_row_tail
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
    input  logic [N_MUL_ROW-1:0]      b_bm [0:15],
    input  logic [15:0][7:0]          a_nz_row,
    input  logic [15:0][7:0]          b_nz [0:15],

    // Accumulation and dump control
    input  logic                      first_pass,
    input  logic [LOCAL_BUF_AW-1:0]   cur_n_base,
    input  logic                      dump_en,
    input  logic [LOCAL_BUF_AW-1:0]   dump_addr,

    // Dump output for this matrix row
    output logic                      c_valid,
    output logic signed [ACC_W-1:0]   c_out
);

    // pe_mfiu_seq -> crossbar
    logic                      m_valid;
    logic [LANE_COUNT_W-1:0]   m_eff;
    logic [N_MUL_ROW-1:0][3:0] m_a_meta;
    logic [N_MUL_ROW-1:0][5:0] m_b_meta;
    logic [3:0]                m_grp_base;
    logic [2:0]                m_grp_ncol;

    // crossbar -> pe_row_tail
    logic [7:0] x_a_val      [0:15];
    logic [7:0] x_b_val      [0:15];
    logic [3:0] x_lane_col   [0:15];
    logic       x_lane_valid [0:15];
    logic       x_valid;

    pe_mfiu_seq u_seq (
        .clk(clk), .rst_n(rst_n),
        .mode(mode), .start(start), .done(done),
        .a_bm_row(a_bm_row), .b_bm(b_bm),
        .out_valid(m_valid), .out_effectual(m_eff),
        .out_a_meta(m_a_meta), .out_b_meta(m_b_meta),
        .out_grp_base(m_grp_base), .out_grp_ncol(m_grp_ncol)
    );

    crossbar u_xbar (
        .valid(m_valid), .effectual(m_eff),
        .a_meta(m_a_meta), .b_meta(m_b_meta), .grp_base(m_grp_base),
        .a_nz_row(a_nz_row), .b_nz(b_nz),
        .a_val(x_a_val), .b_val(x_b_val),
        .lane_col(x_lane_col), .lane_valid(x_lane_valid),
        .valid_out(x_valid)
    );

    pe_row_tail u_tail (
        .clk(clk), .rst_n(rst_n),
        .in_valid(x_valid),
        .a_val(x_a_val), .b_val(x_b_val),
        .lane_col(x_lane_col), .lane_valid(x_lane_valid),
        .first_pass(first_pass), .cur_n_base(cur_n_base),
        .dump_en(dump_en), .dump_addr(dump_addr),
        .c_valid(c_valid), .c_out(c_out)
    );

    // The crossbar derives lane columns from grp_base and b_meta.
    wire _unused = &{1'b0, m_grp_ncol};

endmodule
