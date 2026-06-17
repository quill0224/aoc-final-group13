// =============================================================================
// mfiu_adapter.sv — Per-PE-row Multi-Fiber Intersection Unit
// =============================================================================
// TrIP 交集介面;交集核心採用 mfiu.v(組合掃描器),本檔把它的座標輸出
// 轉成 PE row datapath 要的控制訊號。
//
// 對應 paper Fig 11/12:吃 A/B bitmask,算出 multiplier 該算哪些 effectual 運算,
// 以及結果怎麼路由 / 切 sub-tree。
//
// 交集引擎(本檔內部 instantiate mfiu.v,設為單一 fiber pair):
//   NUM_ROWS=1, NUM_COLS=1, K_BITS=N_MUL_ROW(=16), LANES=N_MUL_ROW(=16)。
//   mfiu.v 掃 a_mask & b_mask 的 16 個 k-slot,把兩邊皆非零者依序壓進 lane。
//   - Dense IP:bitmask 全 1 → 16 lane 全中、k_sel = 0..15(identity pass-through)。
//   - TrIP    :稀疏 bitmask → 只有交集處有效,k_sel 即壓縮後的原始 k 位置。
//   同一顆交集核心涵蓋兩種情況,差別只在輸入 bitmask 稠密度。
//
// 介面對應(mfiu.v 輸出 → 本檔輸出):
//   k_sel        → effectual_idx   (crossbar 要 gather 的原始位置)
//   match_count  → effectual_count (有效 lane 數)
//   (a_row_sel/b_col_sel 在單 fiber 下恆為 0,未使用)
//
// 留給 multi-fiber TrIP packing(trapezoid_pkg N_A_FIBER×N_B_FIBER = 4×4):
//   - cut_after  : 同 cycle pack 多個輸出 C 時的 sub-tree 邊界(目前單一 C → cut=0)
//   - out_addr   : 每個 sub-tree 結果的 C column(目前單一 C 在 cur_n)
//   要啟用多 fiber:把 u_core 改成 NUM_ROWS=N_A_FIBER/NUM_COLS=N_B_FIBER/K_BITS=4,
//   再由 a_row_sel/b_col_sel 的變化推 cut_after(相鄰 lane 座標變了就剪)
//   與 out_addr(b_col 映射到 C column)。
//
// Pipeline:metadata 延 MFIU_STAGES 拍輸出,對齊 pe_row 內被延遲的 A/B 值。
// =============================================================================

module mfiu_adapter
    import trapezoid_pkg::*;
(
    input  logic                                   clk,
    input  logic                                   rst_n,
    input  logic                                   en,
    input  logic                                   in_valid,
    input  logic [1:0]                             dataflow_sel,
    input  logic [LOCAL_BUF_AW-1:0]                cur_n,
    input  logic [N_MUL_ROW-1:0]                   a_bitmask,
    input  logic [N_MUL_ROW-1:0]                   b_bitmask,

    output logic [N_MUL_ROW-1:0][4:0]              effectual_idx,
    output logic [4:0]                             effectual_count,
    output logic [N_MUL_ROW-2:0]                   cut_after,
    output logic [N_MUL_ROW-1:0][LOCAL_BUF_AW-1:0] out_addr,
    output logic                                   meta_valid
);

    // ── intersection core: mfiu.v, configured as one fiber pair × K = N_MUL_ROW ──
    localparam int KB   = N_MUL_ROW;                 // 16 k-slots (= row K dimension)
    localparam int LN   = N_MUL_ROW;                 // up to 16 effectual / cycle
    localparam int KW   = (KB > 1) ? $clog2(KB) : 1; // 4
    localparam int CNTW = $clog2(LN + 1);            // 5

    logic [LN-1:0]    core_valid;
    logic [LN*1-1:0]  core_row_sel;   // NUM_ROWS=1 → 1 bit/lane, all 0 (unused)
    logic [LN*1-1:0]  core_col_sel;   // NUM_COLS=1 → 1 bit/lane, all 0 (unused)
    logic [LN*KW-1:0] core_k_sel;
    logic [CNTW-1:0]  core_count;
    logic             core_overflow;  // never asserts for single fiber (hits <= K = LANES)

    mfiu #(
        .NUM_ROWS (1),
        .NUM_COLS (1),
        .K_BITS   (KB),
        .LANES    (LN)
    ) u_core (
        .a_mask_i      (a_bitmask),
        .b_mask_i      (b_bitmask),
        .lane_valid_o  (core_valid),
        .a_row_sel_o   (core_row_sel),
        .b_col_sel_o   (core_col_sel),
        .k_sel_o       (core_k_sel),
        .match_count_o (core_count),
        .overflow_o    (core_overflow)
    );

    // ── map core coordinates → row control (combinational) ──
    //   effectual_idx[lane] = k_sel[lane]  (original k-position to gather)
    //   out_addr            = single output C at cur_n (last slot), rest 0
    logic [N_MUL_ROW-1:0][4:0]              idx_comb;
    logic [N_MUL_ROW-1:0][LOCAL_BUF_AW-1:0] addr_comb;
    genvar g;
    generate
        for (g = 0; g < N_MUL_ROW; g = g + 1) begin : g_meta
            assign idx_comb[g]  = {{(5-KW){1'b0}}, core_k_sel[g*KW +: KW]};
            assign addr_comb[g] = (g == N_MUL_ROW-1) ? cur_n : {LOCAL_BUF_AW{1'b0}};
        end
    endgenerate

    logic [4:0] cnt_c;
    assign cnt_c = core_count[4:0];

    logic [N_MUL_ROW-2:0] cut_comb;
    assign cut_comb = '0;   // single fiber pair → single sub-tree; multi-fiber cut see header

    // ── delay MFIU_STAGES cycles to align with the data path ──
    logic [N_MUL_ROW-1:0][4:0]              idx_pipe  [MFIU_STAGES];
    logic [N_MUL_ROW-1:0][LOCAL_BUF_AW-1:0] addr_pipe [MFIU_STAGES];
    logic [N_MUL_ROW-2:0]                   cut_pipe  [MFIU_STAGES];
    logic [4:0]                             cnt_pipe  [MFIU_STAGES];
    logic [MFIU_STAGES-1:0]                 vld_pipe;

    integer s;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (s = 0; s < MFIU_STAGES; s = s + 1) begin
                idx_pipe[s] <= '0; addr_pipe[s] <= '0;
                cut_pipe[s] <= '0; cnt_pipe[s] <= '0;
            end
            vld_pipe <= '0;
        end else if (en) begin
            idx_pipe[0]  <= idx_comb;
            addr_pipe[0] <= addr_comb;
            cut_pipe[0]  <= cut_comb;
            cnt_pipe[0]  <= cnt_c;
            for (s = 1; s < MFIU_STAGES; s = s + 1) begin
                idx_pipe[s]  <= idx_pipe[s-1];
                addr_pipe[s] <= addr_pipe[s-1];
                cut_pipe[s]  <= cut_pipe[s-1];
                cnt_pipe[s]  <= cnt_pipe[s-1];
            end
            vld_pipe <= {vld_pipe[MFIU_STAGES-2:0], in_valid};
        end
    end

    assign effectual_idx   = idx_pipe[MFIU_STAGES-1];
    assign effectual_count = cnt_pipe[MFIU_STAGES-1];
    assign cut_after       = cut_pipe[MFIU_STAGES-1];
    assign out_addr        = addr_pipe[MFIU_STAGES-1];
    assign meta_valid      = vld_pipe[MFIU_STAGES-1];

    // dataflow_sel reserved for the multi-fiber TrIP body; sink unused core outputs
    wire _unused = &{1'b0, dataflow_sel, core_valid, core_row_sel, core_col_sel, core_overflow};

endmodule
