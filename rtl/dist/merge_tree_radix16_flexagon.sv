// =============================================================================
// merge_tree_radix16_flexagon.sv — radix-16 reduction tree with sub-tree slicing
// =============================================================================
// Owner: 黃妍心
// Paper: Trapezoid (ISCA'24) §III.B + Flexagon (ASPLOS'23) Fig 4 MRN
//
// 把 16 個 partial products 化簡。依 cut_after 把 tree 切成多棵 contiguous
// sub-tree,每棵產出一個 C 元素(TrIP MS×MS);cut_after=0 時退化成單一 16→1
// 加總(Dense IP)。
//
// 介面:
//   cut_after[14:0]   來自 MFIU,標 sub-tree 邊界(cut_after[i]=1 → 切在 i/i+1 間)
//   subtree_sums[16]  每個位置的 sub-tree 加總(INT32)
//   subtree_valid[16] 該位置是某 sub-tree 終點 → 1
//
// 實作:binary tree,每 node 帶 7 個 state(val_l/r, mask_l/r, pos_l/r,
//   is_single),boundary 8 個 case 決定「合併 / pass / dump」。各 stage 的
//   dump 直接寫 subtree_sums(multi-tap,對齊 paper「each subtree writes
//   directly to local buffer」)。組合邏輯 + 1 個 output register(1 cycle)。
//   不含 comparator / merge mode(TrGT/TrGS 不做);不含 FAN(radix-16 不需要)。
// =============================================================================

module merge_tree_radix16_flexagon
    import trapezoid_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    input  logic                                    en,

    // ── 資料輸入 ──
    input  logic signed [N_MUL_ROW-1:0][PROD_W-1:0] partials,
    input  logic        [N_MUL_ROW-2:0]             cut_after,

    // ── 輸出(registered)──
    output logic signed [N_MUL_ROW-1:0][ACC_W-1:0]  subtree_sums,
    output logic        [N_MUL_ROW-1:0]             subtree_valid
);

    // ============================================================
    // Stage 0:Combinational compute leaf_mask & sign-extend partials
    // ============================================================
    //   leaf_mask[i] = sum(cut_after[0..i-1])
    //   leaf_mask[0] = 0
    //   每 cut_after[i]=1 把後續所有 leaf 的 mask 加 1

    /* verilator lint_off UNOPTFLAT */   // leaf_mask 是 prefix-sum 鏈,非真組合迴路
    logic [3:0]              leaf_mask    [N_MUL_ROW];
    /* verilator lint_on UNOPTFLAT */
    logic signed [ACC_W-1:0] partials_ext [N_MUL_ROW];

    genvar gk;
    generate
        for (gk = 0; gk < N_MUL_ROW; gk = gk + 1) begin : g_ext
            assign partials_ext[gk] =
                {{(ACC_W-PROD_W){partials[gk][PROD_W-1]}}, partials[gk]};
        end
    endgenerate

    // leaf_mask 用 carry-chain 計算(combinational running sum)
    assign leaf_mask[0] = 4'd0;
    genvar gm;
    generate
        for (gm = 1; gm < N_MUL_ROW; gm = gm + 1) begin : g_mask
            assign leaf_mask[gm] = leaf_mask[gm-1] + {3'd0, cut_after[gm-1]};
        end
    endgenerate

    // ============================================================
    // Stage 1:8 nodes,每個合併 2 個 leaf(無 dump)
    // ============================================================
    //   Case 1: mask 相同 → is_single,val_l = val_r = vl + vr
    //   Case 2: mask 不同 → not single,val_l = vl, val_r = vr

    logic signed [ACC_W-1:0] s1_val_l     [8];
    logic signed [ACC_W-1:0] s1_val_r     [8];
    logic [3:0]              s1_mask_l    [8];
    logic [3:0]              s1_mask_r    [8];
    logic [3:0]              s1_pos_l     [8];
    logic [3:0]              s1_pos_r     [8];
    logic                    s1_is_single [8];

    integer s1_i;
    /* verilator lint_off WIDTHTRUNC */  // pos = 2*i(+1),值 0..15,塞 4-bit 安全
    always_comb begin
        for (s1_i = 0; s1_i < 8; s1_i = s1_i + 1) begin
            if (leaf_mask[2*s1_i] == leaf_mask[2*s1_i+1]) begin
                // Same mask → combined single sub-tree
                s1_val_l[s1_i]     = partials_ext[2*s1_i] + partials_ext[2*s1_i+1];
                s1_val_r[s1_i]     = partials_ext[2*s1_i] + partials_ext[2*s1_i+1];
                s1_mask_l[s1_i]    = leaf_mask[2*s1_i];
                s1_mask_r[s1_i]    = leaf_mask[2*s1_i];
                s1_pos_l[s1_i]     = 2*s1_i + 1;
                s1_pos_r[s1_i]     = 2*s1_i + 1;
                s1_is_single[s1_i] = 1'b1;
            end else begin
                // Different masks → 2 separate sub-trees
                s1_val_l[s1_i]     = partials_ext[2*s1_i];
                s1_val_r[s1_i]     = partials_ext[2*s1_i+1];
                s1_mask_l[s1_i]    = leaf_mask[2*s1_i];
                s1_mask_r[s1_i]    = leaf_mask[2*s1_i+1];
                s1_pos_l[s1_i]     = 2*s1_i;
                s1_pos_r[s1_i]     = 2*s1_i + 1;
                s1_is_single[s1_i] = 1'b0;
            end
        end
    end
    /* verilator lint_on WIDTHTRUNC */

    // ============================================================
    // Combine function 共用邏輯(以「local」方式展開,iverilog 友好)
    //   8 case:
    //     Case A (L.mask_r == R.mask_l, boundary merge):
    //       A1: L 跟 R 都 single → 合成 single
    //       A2: L single, R not single → L 併入 R's leftmost subtree
    //       A3: L not single, R single → R 併入 L's rightmost subtree
    //       A4: 都 not single → boundary subtree fully contained,DUMP
    //     Case B (L.mask_r != R.mask_l, boundary):
    //       B1: 都 single → 兩邊都可能延伸,不 dump
    //       B2: L single, R not single → R.val_l contained,dump R.val_l
    //       B3: L not single, R single → L.val_r contained,dump L.val_r
    //       B4: 都 not single → L.val_r 跟 R.val_l 都 contained,2 個 dump
    // ============================================================
    // 為了在 iverilog 跑(沒有 struct 友善 support),用一群信號表達
    // 每個 combine 產生:
    //   new state (7 fields) + up to 2 dumps (each with valid/pos/val)

    // ============================================================
    // Stage 2:4 nodes,每個合併 2 個 s1 node
    // ============================================================
    logic signed [ACC_W-1:0] s2_val_l         [4];
    logic signed [ACC_W-1:0] s2_val_r         [4];
    logic [3:0]              s2_mask_l        [4];
    logic [3:0]              s2_mask_r        [4];
    logic [3:0]              s2_pos_l         [4];
    logic [3:0]              s2_pos_r         [4];
    logic                    s2_is_single     [4];

    logic                    s2_dmp1_valid    [4];
    logic [3:0]              s2_dmp1_pos      [4];
    logic signed [ACC_W-1:0] s2_dmp1_val      [4];
    logic                    s2_dmp2_valid    [4];
    logic [3:0]              s2_dmp2_pos      [4];
    logic signed [ACC_W-1:0] s2_dmp2_val      [4];

    integer s2_i;
    always_comb begin
        for (s2_i = 0; s2_i < 4; s2_i = s2_i + 1) begin : combine_s2
            // 預設清空
            s2_dmp1_valid[s2_i] = 1'b0;
            s2_dmp1_pos[s2_i]   = 4'd0;
            s2_dmp1_val[s2_i]   = '0;
            s2_dmp2_valid[s2_i] = 1'b0;
            s2_dmp2_pos[s2_i]   = 4'd0;
            s2_dmp2_val[s2_i]   = '0;

            if (s1_mask_r[2*s2_i] == s1_mask_l[2*s2_i+1]) begin
                // === Case A: boundary merge ===
                if (s1_is_single[2*s2_i] && s1_is_single[2*s2_i+1]) begin
                    // A1: 都 single → 整段 single
                    s2_val_l[s2_i]     = s1_val_l[2*s2_i] + s1_val_l[2*s2_i+1];
                    s2_val_r[s2_i]     = s1_val_l[2*s2_i] + s1_val_l[2*s2_i+1];
                    s2_mask_l[s2_i]    = s1_mask_l[2*s2_i];
                    s2_mask_r[s2_i]    = s1_mask_l[2*s2_i];
                    s2_pos_l[s2_i]     = s1_pos_r[2*s2_i+1];
                    s2_pos_r[s2_i]     = s1_pos_r[2*s2_i+1];
                    s2_is_single[s2_i] = 1'b1;
                end else if (s1_is_single[2*s2_i] && !s1_is_single[2*s2_i+1]) begin
                    // A2: L single → L 併入 R 的 leftmost
                    s2_val_l[s2_i]     = s1_val_l[2*s2_i] + s1_val_l[2*s2_i+1];
                    s2_val_r[s2_i]     = s1_val_r[2*s2_i+1];
                    s2_mask_l[s2_i]    = s1_mask_l[2*s2_i];
                    s2_mask_r[s2_i]    = s1_mask_r[2*s2_i+1];
                    s2_pos_l[s2_i]     = s1_pos_l[2*s2_i+1];
                    s2_pos_r[s2_i]     = s1_pos_r[2*s2_i+1];
                    s2_is_single[s2_i] = 1'b0;
                end else if (!s1_is_single[2*s2_i] && s1_is_single[2*s2_i+1]) begin
                    // A3: R single → R 併入 L 的 rightmost
                    s2_val_l[s2_i]     = s1_val_l[2*s2_i];
                    s2_val_r[s2_i]     = s1_val_r[2*s2_i] + s1_val_r[2*s2_i+1];
                    s2_mask_l[s2_i]    = s1_mask_l[2*s2_i];
                    s2_mask_r[s2_i]    = s1_mask_r[2*s2_i+1];
                    s2_pos_l[s2_i]     = s1_pos_l[2*s2_i];
                    s2_pos_r[s2_i]     = s1_pos_r[2*s2_i+1];
                    s2_is_single[s2_i] = 1'b0;
                end else begin
                    // A4: 都 not single → boundary subtree DUMP
                    s2_dmp1_valid[s2_i] = 1'b1;
                    s2_dmp1_pos[s2_i]   = s1_pos_l[2*s2_i+1];
                    s2_dmp1_val[s2_i]   = s1_val_r[2*s2_i] + s1_val_l[2*s2_i+1];
                    s2_val_l[s2_i]      = s1_val_l[2*s2_i];
                    s2_val_r[s2_i]      = s1_val_r[2*s2_i+1];
                    s2_mask_l[s2_i]     = s1_mask_l[2*s2_i];
                    s2_mask_r[s2_i]     = s1_mask_r[2*s2_i+1];
                    s2_pos_l[s2_i]      = s1_pos_l[2*s2_i];
                    s2_pos_r[s2_i]      = s1_pos_r[2*s2_i+1];
                    s2_is_single[s2_i]  = 1'b0;
                end
            end else begin
                // === Case B: boundary 不同 ===
                if (s1_is_single[2*s2_i] && s1_is_single[2*s2_i+1]) begin
                    // B1: 都 single → 兩邊都可能延伸,不 dump
                    s2_val_l[s2_i]     = s1_val_l[2*s2_i];
                    s2_val_r[s2_i]     = s1_val_r[2*s2_i+1];
                    s2_mask_l[s2_i]    = s1_mask_l[2*s2_i];
                    s2_mask_r[s2_i]    = s1_mask_r[2*s2_i+1];
                    s2_pos_l[s2_i]     = s1_pos_r[2*s2_i];
                    s2_pos_r[s2_i]     = s1_pos_r[2*s2_i+1];
                    s2_is_single[s2_i] = 1'b0;
                end else if (s1_is_single[2*s2_i] && !s1_is_single[2*s2_i+1]) begin
                    // B2: L single, R not single → dump R.val_l
                    s2_dmp1_valid[s2_i] = 1'b1;
                    s2_dmp1_pos[s2_i]   = s1_pos_l[2*s2_i+1];
                    s2_dmp1_val[s2_i]   = s1_val_l[2*s2_i+1];
                    s2_val_l[s2_i]      = s1_val_l[2*s2_i];
                    s2_val_r[s2_i]      = s1_val_r[2*s2_i+1];
                    s2_mask_l[s2_i]     = s1_mask_l[2*s2_i];
                    s2_mask_r[s2_i]     = s1_mask_r[2*s2_i+1];
                    s2_pos_l[s2_i]      = s1_pos_r[2*s2_i];
                    s2_pos_r[s2_i]      = s1_pos_r[2*s2_i+1];
                    s2_is_single[s2_i]  = 1'b0;
                end else if (!s1_is_single[2*s2_i] && s1_is_single[2*s2_i+1]) begin
                    // B3: L not single, R single → dump L.val_r
                    s2_dmp1_valid[s2_i] = 1'b1;
                    s2_dmp1_pos[s2_i]   = s1_pos_r[2*s2_i];
                    s2_dmp1_val[s2_i]   = s1_val_r[2*s2_i];
                    s2_val_l[s2_i]      = s1_val_l[2*s2_i];
                    s2_val_r[s2_i]      = s1_val_r[2*s2_i+1];
                    s2_mask_l[s2_i]     = s1_mask_l[2*s2_i];
                    s2_mask_r[s2_i]     = s1_mask_r[2*s2_i+1];
                    s2_pos_l[s2_i]      = s1_pos_l[2*s2_i];
                    s2_pos_r[s2_i]      = s1_pos_r[2*s2_i+1];
                    s2_is_single[s2_i]  = 1'b0;
                end else begin
                    // B4: 都 not single → 2 dumps
                    s2_dmp1_valid[s2_i] = 1'b1;
                    s2_dmp1_pos[s2_i]   = s1_pos_r[2*s2_i];
                    s2_dmp1_val[s2_i]   = s1_val_r[2*s2_i];
                    s2_dmp2_valid[s2_i] = 1'b1;
                    s2_dmp2_pos[s2_i]   = s1_pos_l[2*s2_i+1];
                    s2_dmp2_val[s2_i]   = s1_val_l[2*s2_i+1];
                    s2_val_l[s2_i]      = s1_val_l[2*s2_i];
                    s2_val_r[s2_i]      = s1_val_r[2*s2_i+1];
                    s2_mask_l[s2_i]     = s1_mask_l[2*s2_i];
                    s2_mask_r[s2_i]     = s1_mask_r[2*s2_i+1];
                    s2_pos_l[s2_i]      = s1_pos_l[2*s2_i];
                    s2_pos_r[s2_i]      = s1_pos_r[2*s2_i+1];
                    s2_is_single[s2_i]  = 1'b0;
                end
            end
        end
    end

    // ============================================================
    // Stage 3:2 nodes,每個合併 2 個 s2 node(同樣 8-case)
    // ============================================================
    logic signed [ACC_W-1:0] s3_val_l         [2];
    logic signed [ACC_W-1:0] s3_val_r         [2];
    logic [3:0]              s3_mask_l        [2];
    logic [3:0]              s3_mask_r        [2];
    logic [3:0]              s3_pos_l         [2];
    logic [3:0]              s3_pos_r         [2];
    logic                    s3_is_single     [2];
    logic                    s3_dmp1_valid    [2];
    logic [3:0]              s3_dmp1_pos      [2];
    logic signed [ACC_W-1:0] s3_dmp1_val      [2];
    logic                    s3_dmp2_valid    [2];
    logic [3:0]              s3_dmp2_pos      [2];
    logic signed [ACC_W-1:0] s3_dmp2_val      [2];

    integer s3_i;
    always_comb begin
        for (s3_i = 0; s3_i < 2; s3_i = s3_i + 1) begin : combine_s3
            s3_dmp1_valid[s3_i] = 1'b0;
            s3_dmp1_pos[s3_i]   = 4'd0;
            s3_dmp1_val[s3_i]   = '0;
            s3_dmp2_valid[s3_i] = 1'b0;
            s3_dmp2_pos[s3_i]   = 4'd0;
            s3_dmp2_val[s3_i]   = '0;

            if (s2_mask_r[2*s3_i] == s2_mask_l[2*s3_i+1]) begin
                // === Case A ===
                if (s2_is_single[2*s3_i] && s2_is_single[2*s3_i+1]) begin
                    // A1
                    s3_val_l[s3_i]     = s2_val_l[2*s3_i] + s2_val_l[2*s3_i+1];
                    s3_val_r[s3_i]     = s2_val_l[2*s3_i] + s2_val_l[2*s3_i+1];
                    s3_mask_l[s3_i]    = s2_mask_l[2*s3_i];
                    s3_mask_r[s3_i]    = s2_mask_l[2*s3_i];
                    s3_pos_l[s3_i]     = s2_pos_r[2*s3_i+1];
                    s3_pos_r[s3_i]     = s2_pos_r[2*s3_i+1];
                    s3_is_single[s3_i] = 1'b1;
                end else if (s2_is_single[2*s3_i] && !s2_is_single[2*s3_i+1]) begin
                    // A2
                    s3_val_l[s3_i]     = s2_val_l[2*s3_i] + s2_val_l[2*s3_i+1];
                    s3_val_r[s3_i]     = s2_val_r[2*s3_i+1];
                    s3_mask_l[s3_i]    = s2_mask_l[2*s3_i];
                    s3_mask_r[s3_i]    = s2_mask_r[2*s3_i+1];
                    s3_pos_l[s3_i]     = s2_pos_l[2*s3_i+1];
                    s3_pos_r[s3_i]     = s2_pos_r[2*s3_i+1];
                    s3_is_single[s3_i] = 1'b0;
                end else if (!s2_is_single[2*s3_i] && s2_is_single[2*s3_i+1]) begin
                    // A3
                    s3_val_l[s3_i]     = s2_val_l[2*s3_i];
                    s3_val_r[s3_i]     = s2_val_r[2*s3_i] + s2_val_r[2*s3_i+1];
                    s3_mask_l[s3_i]    = s2_mask_l[2*s3_i];
                    s3_mask_r[s3_i]    = s2_mask_r[2*s3_i+1];
                    s3_pos_l[s3_i]     = s2_pos_l[2*s3_i];
                    s3_pos_r[s3_i]     = s2_pos_r[2*s3_i+1];
                    s3_is_single[s3_i] = 1'b0;
                end else begin
                    // A4 → DUMP
                    s3_dmp1_valid[s3_i] = 1'b1;
                    s3_dmp1_pos[s3_i]   = s2_pos_l[2*s3_i+1];
                    s3_dmp1_val[s3_i]   = s2_val_r[2*s3_i] + s2_val_l[2*s3_i+1];
                    s3_val_l[s3_i]      = s2_val_l[2*s3_i];
                    s3_val_r[s3_i]      = s2_val_r[2*s3_i+1];
                    s3_mask_l[s3_i]     = s2_mask_l[2*s3_i];
                    s3_mask_r[s3_i]     = s2_mask_r[2*s3_i+1];
                    s3_pos_l[s3_i]      = s2_pos_l[2*s3_i];
                    s3_pos_r[s3_i]      = s2_pos_r[2*s3_i+1];
                    s3_is_single[s3_i]  = 1'b0;
                end
            end else begin
                // === Case B ===
                if (s2_is_single[2*s3_i] && s2_is_single[2*s3_i+1]) begin
                    // B1
                    s3_val_l[s3_i]     = s2_val_l[2*s3_i];
                    s3_val_r[s3_i]     = s2_val_r[2*s3_i+1];
                    s3_mask_l[s3_i]    = s2_mask_l[2*s3_i];
                    s3_mask_r[s3_i]    = s2_mask_r[2*s3_i+1];
                    s3_pos_l[s3_i]     = s2_pos_r[2*s3_i];
                    s3_pos_r[s3_i]     = s2_pos_r[2*s3_i+1];
                    s3_is_single[s3_i] = 1'b0;
                end else if (s2_is_single[2*s3_i] && !s2_is_single[2*s3_i+1]) begin
                    // B2: dump R.val_l
                    s3_dmp1_valid[s3_i] = 1'b1;
                    s3_dmp1_pos[s3_i]   = s2_pos_l[2*s3_i+1];
                    s3_dmp1_val[s3_i]   = s2_val_l[2*s3_i+1];
                    s3_val_l[s3_i]      = s2_val_l[2*s3_i];
                    s3_val_r[s3_i]      = s2_val_r[2*s3_i+1];
                    s3_mask_l[s3_i]     = s2_mask_l[2*s3_i];
                    s3_mask_r[s3_i]     = s2_mask_r[2*s3_i+1];
                    s3_pos_l[s3_i]      = s2_pos_r[2*s3_i];
                    s3_pos_r[s3_i]      = s2_pos_r[2*s3_i+1];
                    s3_is_single[s3_i]  = 1'b0;
                end else if (!s2_is_single[2*s3_i] && s2_is_single[2*s3_i+1]) begin
                    // B3: dump L.val_r
                    s3_dmp1_valid[s3_i] = 1'b1;
                    s3_dmp1_pos[s3_i]   = s2_pos_r[2*s3_i];
                    s3_dmp1_val[s3_i]   = s2_val_r[2*s3_i];
                    s3_val_l[s3_i]      = s2_val_l[2*s3_i];
                    s3_val_r[s3_i]      = s2_val_r[2*s3_i+1];
                    s3_mask_l[s3_i]     = s2_mask_l[2*s3_i];
                    s3_mask_r[s3_i]     = s2_mask_r[2*s3_i+1];
                    s3_pos_l[s3_i]      = s2_pos_l[2*s3_i];
                    s3_pos_r[s3_i]      = s2_pos_r[2*s3_i+1];
                    s3_is_single[s3_i]  = 1'b0;
                end else begin
                    // B4: 2 dumps
                    s3_dmp1_valid[s3_i] = 1'b1;
                    s3_dmp1_pos[s3_i]   = s2_pos_r[2*s3_i];
                    s3_dmp1_val[s3_i]   = s2_val_r[2*s3_i];
                    s3_dmp2_valid[s3_i] = 1'b1;
                    s3_dmp2_pos[s3_i]   = s2_pos_l[2*s3_i+1];
                    s3_dmp2_val[s3_i]   = s2_val_l[2*s3_i+1];
                    s3_val_l[s3_i]      = s2_val_l[2*s3_i];
                    s3_val_r[s3_i]      = s2_val_r[2*s3_i+1];
                    s3_mask_l[s3_i]     = s2_mask_l[2*s3_i];
                    s3_mask_r[s3_i]     = s2_mask_r[2*s3_i+1];
                    s3_pos_l[s3_i]      = s2_pos_l[2*s3_i];
                    s3_pos_r[s3_i]      = s2_pos_r[2*s3_i+1];
                    s3_is_single[s3_i]  = 1'b0;
                end
            end
        end
    end

    // ============================================================
    // Stage 4:1 root node,合併 2 個 s3 node(同樣 8-case)
    // ============================================================
    logic signed [ACC_W-1:0] s4_val_l;
    logic signed [ACC_W-1:0] s4_val_r;
    logic [3:0]              s4_mask_l;
    logic [3:0]              s4_mask_r;
    logic [3:0]              s4_pos_l;
    logic [3:0]              s4_pos_r;
    logic                    s4_is_single;
    logic                    s4_dmp1_valid;
    logic [3:0]              s4_dmp1_pos;
    logic signed [ACC_W-1:0] s4_dmp1_val;
    logic                    s4_dmp2_valid;
    logic [3:0]              s4_dmp2_pos;
    logic signed [ACC_W-1:0] s4_dmp2_val;

    always_comb begin
        s4_dmp1_valid = 1'b0;
        s4_dmp1_pos   = 4'd0;
        s4_dmp1_val   = '0;
        s4_dmp2_valid = 1'b0;
        s4_dmp2_pos   = 4'd0;
        s4_dmp2_val   = '0;

        if (s3_mask_r[0] == s3_mask_l[1]) begin
            // === Case A ===
            if (s3_is_single[0] && s3_is_single[1]) begin
                s4_val_l     = s3_val_l[0] + s3_val_l[1];
                s4_val_r     = s3_val_l[0] + s3_val_l[1];
                s4_mask_l    = s3_mask_l[0];
                s4_mask_r    = s3_mask_l[0];
                s4_pos_l     = s3_pos_r[1];
                s4_pos_r     = s3_pos_r[1];
                s4_is_single = 1'b1;
            end else if (s3_is_single[0] && !s3_is_single[1]) begin
                s4_val_l     = s3_val_l[0] + s3_val_l[1];
                s4_val_r     = s3_val_r[1];
                s4_mask_l    = s3_mask_l[0];
                s4_mask_r    = s3_mask_r[1];
                s4_pos_l     = s3_pos_l[1];
                s4_pos_r     = s3_pos_r[1];
                s4_is_single = 1'b0;
            end else if (!s3_is_single[0] && s3_is_single[1]) begin
                s4_val_l     = s3_val_l[0];
                s4_val_r     = s3_val_r[0] + s3_val_r[1];
                s4_mask_l    = s3_mask_l[0];
                s4_mask_r    = s3_mask_r[1];
                s4_pos_l     = s3_pos_l[0];
                s4_pos_r     = s3_pos_r[1];
                s4_is_single = 1'b0;
            end else begin
                // A4 → DUMP
                s4_dmp1_valid = 1'b1;
                s4_dmp1_pos   = s3_pos_l[1];
                s4_dmp1_val   = s3_val_r[0] + s3_val_l[1];
                s4_val_l      = s3_val_l[0];
                s4_val_r      = s3_val_r[1];
                s4_mask_l     = s3_mask_l[0];
                s4_mask_r     = s3_mask_r[1];
                s4_pos_l      = s3_pos_l[0];
                s4_pos_r      = s3_pos_r[1];
                s4_is_single  = 1'b0;
            end
        end else begin
            // === Case B ===
            if (s3_is_single[0] && s3_is_single[1]) begin
                s4_val_l     = s3_val_l[0];
                s4_val_r     = s3_val_r[1];
                s4_mask_l    = s3_mask_l[0];
                s4_mask_r    = s3_mask_r[1];
                s4_pos_l     = s3_pos_r[0];
                s4_pos_r     = s3_pos_r[1];
                s4_is_single = 1'b0;
            end else if (s3_is_single[0] && !s3_is_single[1]) begin
                s4_dmp1_valid = 1'b1;
                s4_dmp1_pos   = s3_pos_l[1];
                s4_dmp1_val   = s3_val_l[1];
                s4_val_l      = s3_val_l[0];
                s4_val_r      = s3_val_r[1];
                s4_mask_l     = s3_mask_l[0];
                s4_mask_r     = s3_mask_r[1];
                s4_pos_l      = s3_pos_r[0];
                s4_pos_r      = s3_pos_r[1];
                s4_is_single  = 1'b0;
            end else if (!s3_is_single[0] && s3_is_single[1]) begin
                s4_dmp1_valid = 1'b1;
                s4_dmp1_pos   = s3_pos_r[0];
                s4_dmp1_val   = s3_val_r[0];
                s4_val_l      = s3_val_l[0];
                s4_val_r      = s3_val_r[1];
                s4_mask_l     = s3_mask_l[0];
                s4_mask_r     = s3_mask_r[1];
                s4_pos_l      = s3_pos_l[0];
                s4_pos_r      = s3_pos_r[1];
                s4_is_single  = 1'b0;
            end else begin
                s4_dmp1_valid = 1'b1;
                s4_dmp1_pos   = s3_pos_r[0];
                s4_dmp1_val   = s3_val_r[0];
                s4_dmp2_valid = 1'b1;
                s4_dmp2_pos   = s3_pos_l[1];
                s4_dmp2_val   = s3_val_l[1];
                s4_val_l      = s3_val_l[0];
                s4_val_r      = s3_val_r[1];
                s4_mask_l     = s3_mask_l[0];
                s4_mask_r     = s3_mask_r[1];
                s4_pos_l      = s3_pos_l[0];
                s4_pos_r      = s3_pos_r[1];
                s4_is_single  = 1'b0;
            end
        end
    end

    // ============================================================
    // Final flush:root 之後,把 root.val_l 跟 root.val_r dump 出去
    //   - 如果 is_single,val_l == val_r,只 dump 一次
    //   - 不 single,dump 兩次(位置不同)
    // ============================================================
    logic                    final_dmp_l_valid;
    logic [3:0]              final_dmp_l_pos;
    logic signed [ACC_W-1:0] final_dmp_l_val;
    logic                    final_dmp_r_valid;
    logic [3:0]              final_dmp_r_pos;
    logic signed [ACC_W-1:0] final_dmp_r_val;

    always_comb begin
        final_dmp_l_valid = 1'b1;
        final_dmp_l_pos   = s4_pos_l;
        final_dmp_l_val   = s4_val_l;
        if (s4_is_single) begin
            final_dmp_r_valid = 1'b0;
            final_dmp_r_pos   = 4'd0;
            final_dmp_r_val   = '0;
        end else begin
            final_dmp_r_valid = 1'b1;
            final_dmp_r_pos   = s4_pos_r;
            final_dmp_r_val   = s4_val_r;
        end
    end

    // ============================================================
    // 把所有 stage 的 dumps 收進 subtree_sums[16] / subtree_valid[16]
    //   每個 position 最多會有一個 dump source(因為 sub-tree 結束位置唯一)
    //   用 priority OR 收集
    // ============================================================
    logic signed [ACC_W-1:0] sums_comb  [N_MUL_ROW];
    logic                    valid_comb [N_MUL_ROW];

    integer ic;
    integer ks2, ks3;

    always_comb begin
        // 預設 0
        for (ic = 0; ic < N_MUL_ROW; ic = ic + 1) begin
            sums_comb[ic]  = '0;
            valid_comb[ic] = 1'b0;
        end

        // Stage 2 dumps (8 個 potential dumps from 4 nodes × 2 dump slots)
        for (ks2 = 0; ks2 < 4; ks2 = ks2 + 1) begin
            if (s2_dmp1_valid[ks2]) begin
                sums_comb[s2_dmp1_pos[ks2]]  = s2_dmp1_val[ks2];
                valid_comb[s2_dmp1_pos[ks2]] = 1'b1;
            end
            if (s2_dmp2_valid[ks2]) begin
                sums_comb[s2_dmp2_pos[ks2]]  = s2_dmp2_val[ks2];
                valid_comb[s2_dmp2_pos[ks2]] = 1'b1;
            end
        end

        // Stage 3 dumps
        for (ks3 = 0; ks3 < 2; ks3 = ks3 + 1) begin
            if (s3_dmp1_valid[ks3]) begin
                sums_comb[s3_dmp1_pos[ks3]]  = s3_dmp1_val[ks3];
                valid_comb[s3_dmp1_pos[ks3]] = 1'b1;
            end
            if (s3_dmp2_valid[ks3]) begin
                sums_comb[s3_dmp2_pos[ks3]]  = s3_dmp2_val[ks3];
                valid_comb[s3_dmp2_pos[ks3]] = 1'b1;
            end
        end

        // Stage 4 (root) dumps
        if (s4_dmp1_valid) begin
            sums_comb[s4_dmp1_pos]  = s4_dmp1_val;
            valid_comb[s4_dmp1_pos] = 1'b1;
        end
        if (s4_dmp2_valid) begin
            sums_comb[s4_dmp2_pos]  = s4_dmp2_val;
            valid_comb[s4_dmp2_pos] = 1'b1;
        end

        // Final flush
        if (final_dmp_l_valid) begin
            sums_comb[final_dmp_l_pos]  = final_dmp_l_val;
            valid_comb[final_dmp_l_pos] = 1'b1;
        end
        if (final_dmp_r_valid) begin
            sums_comb[final_dmp_r_pos]  = final_dmp_r_val;
            valid_comb[final_dmp_r_pos] = 1'b1;
        end
    end

    // ============================================================
    // Output register(1 cycle latency)
    // ============================================================
    integer ko;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (ko = 0; ko < N_MUL_ROW; ko = ko + 1) begin
                subtree_sums[ko]  <= '0;
                subtree_valid[ko] <= 1'b0;
            end
        end else if (en) begin
            for (ko = 0; ko < N_MUL_ROW; ko = ko + 1) begin
                subtree_sums[ko]  <= sums_comb[ko];
                subtree_valid[ko] <= valid_comb[ko];
            end
        end
    end

endmodule
