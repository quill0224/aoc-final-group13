// =============================================================================
// mfiu_trip.sv — TrIP 交集轉換層(內含 mfiu.v 核心)
// =============================================================================
// 功能:
//   內含組合交集核心 mfiu.v,把它的座標輸出原樣透出給後段,並只額外推一個
//   座標本身給不出、而 reduction tree 需要的訊號:cut_after。
//   設計原則:翻譯最少、保留上游語意 —— routing / 位址的攤平交給真正知道
//   bus 佈局的消費端(distribution / local buffer)做,本層不提早假設。
//
//   透出(沿用 mfiu.v 命名,per-lane,只前 LN 個 lane 有效):
//     lane_valid / a_row_sel / b_col_sel / k_sel   每 lane 的座標
//     match_count / overflow                       有效數 / 命中 > LANES
//   額外推導:
//     cut_after   相鄰有效 lane 屬不同輸出 C(a_row,b_col 不同)→ 子樹邊界
//
// 為何 cut_after 要在這裡推:
//   reduction tree 需要「哪些 lane 加在同一棵子樹」,但 (a_row,b_col,k) 座標
//   本身表達不出分段;mfiu.v 的掃描序為 (r,c,k),同一輸出 C 的命中必相鄰,
//   故取「相鄰有效 lane 的 (a_row,b_col) 變了就剪」。
//
// 介面:
//   a_bitmask / b_bitmask  in   [NR*KB]、[NC*KB] bit(每 fiber 的 K-slot bitmask)
//   lane_valid             out  [LN]      各 lane 是否有效
//   a_row_sel / b_col_sel / k_sel  out    各 lane 的 A fiber / B fiber / k-slot index
//   match_count            out            有效運算數(0..LANES)
//   overflow               out  1         命中 > LANES(需 replay)
//   cut_after              out  [14:0]    子樹邊界(對齊 16-lane tree)
//
// 待確認的假設(LANES=4 先行版):
//   NR=NC=4, KB=4, LANES=4(對應 a_bitmask 16-bit = 4 fiber × 4 k);
//   bitmask 佈局 fiber r 在 bit[r*KB +: KB];真版參數定了改這裡即可。
// =============================================================================

module mfiu_trip
    import trapezoid_pkg::*;
#(
    parameter int NR = 4,   // A fibers (rows)
    parameter int NC = 4,   // B fibers (cols)
    parameter int KB = 4,   // k-slots / fiber
    parameter int LN = 4,   // lanes (= effectual MACs / cycle)
    // Derived widths — do not override
    parameter int RW   = (NR > 1) ? $clog2(NR) : 1,
    parameter int CW   = (NC > 1) ? $clog2(NC) : 1,
    parameter int KW   = (KB > 1) ? $clog2(KB) : 1,
    parameter int CNTW = $clog2(LN + 1)
)(
    input  logic [N_MUL_ROW-1:0]  a_bitmask,
    input  logic [N_MUL_ROW-1:0]  b_bitmask,

    // ── Pass through mfiu.v coordinates (reusing its naming) ──
    output logic [LN-1:0]         lane_valid,
    output logic [LN*RW-1:0]      a_row_sel,
    output logic [LN*CW-1:0]      b_col_sel,
    output logic [LN*KW-1:0]      k_sel,
    output logic [CNTW-1:0]       match_count,
    output logic                  overflow,

    // ── Only extra derivation: subtree boundaries for the reduction tree ──
    output logic [N_MUL_ROW-2:0]  cut_after
);
    // ── Combinational intersection core mfiu.v (coordinates passed through as-is) ──
    mfiu #(.NUM_ROWS(NR), .NUM_COLS(NC), .K_BITS(KB), .LANES(LN)) u_core (
        .a_mask_i      (a_bitmask[NR*KB-1:0]),
        .b_mask_i      (b_bitmask[NC*KB-1:0]),
        .lane_valid_o  (lane_valid),
        .a_row_sel_o   (a_row_sel),
        .b_col_sel_o   (b_col_sel),
        .k_sel_o       (k_sel),
        .match_count_o (match_count),
        .overflow_o    (overflow)
    );

    // ── Unpack coordinates (constant genvar index → iverilog-safe) ──
    logic          uv   [LN];
    logic [RW-1:0] urow [LN];
    logic [CW-1:0] ucol [LN];
    genvar gl;
    generate
        for (gl = 0; gl < LN; gl = gl + 1) begin : g_unpack
            assign uv[gl]   = lane_valid[gl];
            assign urow[gl] = a_row_sel[gl*RW +: RW];
            assign ucol[gl] = b_col_sel[gl*CW +: CW];
        end
    endgenerate

    // ── Derive cut_after: cut when adjacent valid lanes target a different output C (a_row,b_col) ──
    //   Two lanes share an output ⇔ both a_row and b_col match. Scan order guarantees same-output lanes are adjacent.
    logic [N_MUL_ROW-2:0] cut_c;
    integer i;
    always_comb begin
        cut_c = '0;
        for (i = 0; i < LN-1; i = i + 1) begin
            if (uv[i] && uv[i+1] &&
                ((urow[i] != urow[i+1]) || (ucol[i] != ucol[i+1])))
                cut_c[i] = 1'b1;
        end
    end
    assign cut_after = cut_c;

endmodule
