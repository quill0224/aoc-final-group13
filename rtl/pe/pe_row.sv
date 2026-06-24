// =============================================================================
// pe_row.sv
// =============================================================================
// 把三個模組串成「一條 PE row 的計算鏈」:
//   pe_mfiu_seq(+mfiu) → crossbar → pe_row_tail
//
//   * A/B 來源是「共享的 pe_ab_buffer」(在 pe_array 層、16 條 row 共用一顆):
//       a_bm_row / a_nz_row = buffer 第 r 條 A fiber(此 row 專屬)
//       b_bm[*]   / b_nz[*]  = 16 條 B 欄(所有 row 共享)
//   * mode/first_pass/cur_n_base/dump_* 由 controller 廣播。
//   * done = 此 row 的 mfiu_seq 把所有 B-group 跑完(注意:tail 後段還有 ~4 拍
//     drain;陣列層的 pe_compute_done 應 = AND(16 row done) 再延遲 drain margin,
//     才能保證 local_buffer 累加落定 / 可換下一批 tile)。
//
// =============================================================================

module pe_row
    import trapezoid_pkg::*;
(
    input  logic                      clk,
    input  logic                      rst_n,

    // ── controller ──
    input  logic                      mode,          // 1=TrIP
    input  logic                      start,         // = pe_ab_buffer.tile_ready(開始處理本 tile)
    output logic                      done,           // 本 row 的 mfiu_seq 跑完所有 B-group

    // ── 共享 pe_ab_buffer(此 row 的 A + 共享 B)──
    input  logic [N_MUL_ROW-1:0]      a_bm_row,       // = buffer.a_bm[r]
    input  logic [N_MUL_ROW-1:0]      b_bm [0:15],    // = buffer.b_bm(共享)
    input  logic [15:0][7:0]          a_nz_row,       // = buffer.a_nz[r]
    input  logic [15:0][7:0]          b_nz [0:15],    // = buffer.b_nz(共享)

    // ── controller 廣播給 tail ──
    input  logic                      first_pass,
    input  logic [LOCAL_BUF_AW-1:0]   cur_n_base,
    input  logic                      dump_en,
    input  logic [LOCAL_BUF_AW-1:0]   dump_addr,

    // ── 輸出(此 row = 輸出列 m)──
    output logic                      c_valid,
    output logic signed [ACC_W-1:0]   c_out
);

    // ── pe_mfiu_seq → crossbar ──
    logic                      m_valid;
    logic [LANE_COUNT_W-1:0]   m_eff;
    logic [N_MUL_ROW-1:0][3:0] m_a_meta;
    logic [N_MUL_ROW-1:0][5:0] m_b_meta;
    logic [3:0]                m_grp_base;
    logic [2:0]                m_grp_ncol;     // crossbar 不用(欄位由 grp_base+b_meta 自算)

    // ── crossbar → pe_row_tail ──
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

    // grp_ncol 目前未用
    wire _unused = &{1'b0, m_grp_ncol};

endmodule
