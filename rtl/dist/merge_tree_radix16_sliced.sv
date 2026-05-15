// =============================================================================
// merge_tree_radix16_sliced.sv — Reduction tree with contiguous sub-tree slicing
// =============================================================================
// === 模組 OWNER: 黃妍心 + QuillQ ===
//
// 用途:
//   TrIP 模式下,把 16 個 partial products 切成多個 contiguous sub-tree,
//   各自加總成獨立 C 元素(對應 paper Fig 10 範例)。
//   Dense IP / MS×D 模式下(cut_after = 0),退化成單一 16→1 加總,
//   行為等同舊版 merge_tree_radix16.sv。
//
// === Paper 設計參考 ===
//   - ISCA 2024 Trapezoid §III.B (Reductions and output buffering):
//     "the tree can be sliced to smaller subtrees, each accumulating a
//      contiguous subset of input elements. TrIP configures subtrees
//      so that each subtree produces one element of C."
//   - Trapezoid paper Fig 10:TrIP MS×MS 4-mul row 範例切成 3 個 sub-tree
//   - Flexagon (Muñoz-Martínez et al. ASPLOS'23 ref [50]) MRN 設計
//
// === 演算法: Kogge-Stone Parallel Prefix Sum with Selective Reset ===
//   觀察: subtree_sum_ending_at[i] = sum(partials[start..i]),
//        其中 start = position right after the most recent cut before i
//   實作: 4-stage parallel prefix,在每個 stride 檢查「該範圍內有沒有 cut」,
//        有 cut → 不合併(等於 reset)
//
// === Pipeline: 4 stages, latency = 4 cycles(跟原 merge_tree_radix16 一致)===
//   Stage 1 (stride 1):各 pair (i-1, i) 條件合併
//   Stage 2 (stride 2):各 (i-2, i) 跨距離合併
//   Stage 3 (stride 4):各 (i-4, i)
//   Stage 4 (stride 8):各 (i-8, i)
//
// === Bit-width 簡化策略 ===
//   原始設計每 stage 位寬遞增(INT17→INT18→INT19→INT20),概念上更省 area。
//   實作上為了避開 iverilog 對 "packed array + variable index + bit-select"
//   的限制,**全部 stage 內部都用 INT32(ACC_W)儲存**,只在進 stage 1 之前
//   把 partials 從 INT16 sign-extend 到 INT32。
//   功能上等價,只是 register 寬度大一點(synth 後 unused bit 會被 optimize 掉)。
//
// === 介面 ===
//   cut_after[i] = 1 表示 partials[i] 跟 partials[i+1] 之間切斷(15 bits)
//   subtree_valid[i] = 1 表示 position i 是某個 sub-tree 的終點
//   subtree_sums[i]  = 那個 sub-tree 的加總值 (INT32)
//
// === Backward 相容性驗證 ===
//   cut_after = 0  → subtree_valid = 16'b1000_0000_0000_0000(只 [15] 為 1)
//                 → subtree_sums[15] = 全 16 個 partials 加總
//                 → 等同舊版 merge_tree_radix16
//
// === TODO(週末 / Phase 2 後續)===
//   1. valid signal pipeline(隨 4 stage 走,目前簡化用 cut_s4 控)
//   2. 跟 MFIU 對齊 cut_after 的時序與來源
//   3. P&R timing 驗證
//   4. 加 assertion 確保 cut_after 合法
// =============================================================================

module merge_tree_radix16_sliced
    import trapezoid_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    input  logic                                    en,

    // ── 資料輸入 ──
    input  logic signed [N_MUL_ROW-1:0][PROD_W-1:0] partials,    // 16 × INT16
    input  logic        [N_MUL_ROW-2:0]             cut_after,   // 15 bits

    // ── 輸出 ──
    output logic signed [N_MUL_ROW-1:0][ACC_W-1:0]  subtree_sums,
    output logic        [N_MUL_ROW-1:0]             subtree_valid
);

    // ============================================================
    // Pre-extend partials to ACC_W (INT32) via generate + assign
    //   避開在 always_ff 內做 bit-select(iverilog 不接受)
    // ============================================================
    logic signed [ACC_W-1:0] partials_ext [N_MUL_ROW];

    genvar gk;
    generate
        for (gk = 0; gk < N_MUL_ROW; gk = gk + 1) begin : g_ext_partials
            // sign-extend INT16 → INT32(複製符號位 ACC_W-PROD_W=16 次)
            assign partials_ext[gk] = {{(ACC_W-PROD_W){partials[gk][PROD_W-1]}}, partials[gk]};
        end
    endgenerate

    // ============================================================
    // Pipeline 內部訊號(unpacked array,全用 INT32 寬度)
    //   P1: stage 1 出
    //   P2: stage 2 出
    //   P3: stage 3 出
    //   P4: stage 4 出
    //   cut_sN: cut_after 在第 N stage 後的副本
    // ============================================================
    logic signed [ACC_W-1:0] P1 [N_MUL_ROW];
    logic signed [ACC_W-1:0] P2 [N_MUL_ROW];
    logic signed [ACC_W-1:0] P3 [N_MUL_ROW];
    logic signed [ACC_W-1:0] P4 [N_MUL_ROW];

    logic [N_MUL_ROW-2:0] cut_s1, cut_s2, cut_s3, cut_s4;

    // ============================================================
    // Stage 1 (stride 1):
    //   For i ∈ [1..15]:
    //     若 cut_after[i-1] = 1 → P1[i] = partials_ext[i]      (不合)
    //     否則                   → P1[i] = partials_ext[i-1]
    //                                     + partials_ext[i]    (合)
    //   P1[0] 永遠是 partials_ext[0]
    // ============================================================
    integer k1;
    integer i1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k1 = 0; k1 < N_MUL_ROW; k1 = k1 + 1)
                P1[k1] <= '0;
            cut_s1 <= '0;
        end else if (en) begin
            P1[0] <= partials_ext[0];
            for (i1 = 1; i1 < N_MUL_ROW; i1 = i1 + 1) begin
                if (cut_after[i1-1])
                    P1[i1] <= partials_ext[i1];
                else
                    P1[i1] <= partials_ext[i1-1] + partials_ext[i1];
            end
            cut_s1 <= cut_after;
        end
    end

    // ============================================================
    // Stage 2 (stride 2):
    //   For i ∈ [2..15]:
    //     若 cut_s1[i-1] 或 cut_s1[i-2] 任一 = 1 → 不合
    //     否則                                   → P2[i] = P1[i] + P1[i-2]
    // ============================================================
    integer k2;
    integer i2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k2 = 0; k2 < N_MUL_ROW; k2 = k2 + 1)
                P2[k2] <= '0;
            cut_s2 <= '0;
        end else if (en) begin
            P2[0] <= P1[0];
            P2[1] <= P1[1];
            for (i2 = 2; i2 < N_MUL_ROW; i2 = i2 + 1) begin
                if (cut_s1[i2-1] | cut_s1[i2-2])
                    P2[i2] <= P1[i2];
                else
                    P2[i2] <= P1[i2] + P1[i2-2];
            end
            cut_s2 <= cut_s1;
        end
    end

    // ============================================================
    // Stage 3 (stride 4):
    //   For i ∈ [4..15]:
    //     若 cut_s2[i-1..i-4] 任一 = 1 → 不合
    //     否則                          → P3[i] = P2[i] + P2[i-4]
    // ============================================================
    integer k3;
    integer i3;
    integer j3;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k3 = 0; k3 < N_MUL_ROW; k3 = k3 + 1)
                P3[k3] <= '0;
            cut_s3 <= '0;
        end else if (en) begin
            for (j3 = 0; j3 < 4; j3 = j3 + 1)
                P3[j3] <= P2[j3];
            for (i3 = 4; i3 < N_MUL_ROW; i3 = i3 + 1) begin
                if (cut_s2[i3-1] | cut_s2[i3-2] | cut_s2[i3-3] | cut_s2[i3-4])
                    P3[i3] <= P2[i3];
                else
                    P3[i3] <= P2[i3] + P2[i3-4];
            end
            cut_s3 <= cut_s2;
        end
    end

    // ============================================================
    // Stage 4 (stride 8):
    //   For i ∈ [8..15]:
    //     若 cut_s3[i-1..i-8] 任一 = 1 → 不合
    //     否則                          → P4[i] = P3[i] + P3[i-8]
    // ============================================================
    integer k4;
    integer i4;
    integer j4;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k4 = 0; k4 < N_MUL_ROW; k4 = k4 + 1)
                P4[k4] <= '0;
            cut_s4 <= '0;
        end else if (en) begin
            for (j4 = 0; j4 < 8; j4 = j4 + 1)
                P4[j4] <= P3[j4];
            for (i4 = 8; i4 < N_MUL_ROW; i4 = i4 + 1) begin
                if (cut_s3[i4-1] | cut_s3[i4-2] | cut_s3[i4-3] | cut_s3[i4-4]
                  | cut_s3[i4-5] | cut_s3[i4-6] | cut_s3[i4-7] | cut_s3[i4-8])
                    P4[i4] <= P3[i4];
                else
                    P4[i4] <= P3[i4] + P3[i4-8];
            end
            cut_s4 <= cut_s3;
        end
    end

    // ============================================================
    // 輸出階段(組合邏輯)
    //   subtree_valid[i] = cut_s4[i] (i ∈ [0..14]) 或 1 (i == 15)
    //   subtree_sums[i]  = P4[i](INT32,直接 copy 不用 extend)
    // ============================================================
    integer ko;
    always_comb begin
        // Default: invalid + 0
        for (ko = 0; ko < N_MUL_ROW; ko = ko + 1) begin
            subtree_valid[ko] = 1'b0;
            subtree_sums[ko]  = '0;
        end

        // 對 i ∈ [0..14]:看 cut_s4[i]
        for (ko = 0; ko < N_MUL_ROW - 1; ko = ko + 1) begin
            if (cut_s4[ko]) begin
                subtree_valid[ko] = 1'b1;
                subtree_sums[ko]  = P4[ko];
            end
        end

        // i = 15:永遠是某個 sub-tree 的結尾
        subtree_valid[N_MUL_ROW-1] = 1'b1;
        subtree_sums[N_MUL_ROW-1]  = P4[N_MUL_ROW-1];
    end

endmodule
