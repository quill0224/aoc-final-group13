// =============================================================================
// reduction_tree_radix16.sv — radix-16 reduction tree (sub-tree slicing)
// =============================================================================
// Function:
//   Partition the 16 partial products into contiguous segments (sub-trees) by
//   cut_after, and sum each segment in parallel within a single cycle.
//   cut_after[i]=1 marks a boundary between lane i and lane i+1 (lane i is the
//   last lane of its segment); cut_after=0 means all 16 lanes form one segment
//   (16->1 full sum). Up to 16 segments (each lane its own segment). Partials
//   are sign-extended to ACC_W before summing; intermediate results do not
//   overflow.
//
// Output semantics:
//   subtree_valid[p]=1 means position p is a segment's last lane;
//   subtree_sums[p] = sum of all partials in that segment. Other positions
//   have valid=0, sums=0. Segment-end positions are unique, so each output
//   position carries at most one segment result.
//
// Interface:
//   clk / rst_n / en           clock; async reset (active-low); en=0 holds output
//   partials  [16][PROD_W] in  16 partial products (signed)
//   cut_after [14:0]       in  segment boundaries, aligned with partials
//   subtree_sums  [16][ACC_W] out  per-segment sums (signed, registered)
//   subtree_valid [16]        out  segment-end position markers (registered)
//
// Timing:
//   Fully combinational compute + output register: latency = 1 cycle,
//   throughput = one set per cycle (cut_after may differ each cycle,
//   cycles are independent).
//
// Structure:
//   1) leaf_mask: prefix-sum of cut_after, tagging each lane with its segment id.
//   2) 4 binary merge stages (8->4->2->1 node): each node maintains running
//      state (val / mask / pos / is_single) for its left and right ends, and
//      uses 8 cases (left/right segment id equal or not x each side closed or
//      not) to decide merge, pass-through, or dump.
//   3) When a segment is fully contained within the tree, dump it at that level:
//      the sum is written directly to the segment-end position (multi-tap
//      output); after the root, a final flush emits the leftmost and rightmost
//      segments.
//
// Scope:
//   Reduce only (segment sums). TrGT / TrGS comparator / merge modes are not
//   in this module.
//
// Datapath position:
//   Upstream: mul array feeds 16 partial products; cut_after comes from MFIU,
//             delay-aligned by an upper level to the same cycle as partials.
//   This stage: S7 (segment sum) of pe_row_full.
//   Downstream: 16->4 compression layer -> local_buffer_row (segment results
//               delivered by segment-end position).
// =============================================================================

module reduction_tree_radix16
    import trapezoid_pkg::*;
(
    input  logic                                    clk,
    input  logic                                    rst_n,
    input  logic                                    en,

    // ── Data inputs ──
    input  logic signed [N_MUL_ROW-1:0][PROD_W-1:0] partials,
    input  logic        [N_MUL_ROW-2:0]             cut_after,

    // ── Outputs (registered) ──
    output logic signed [N_MUL_ROW-1:0][ACC_W-1:0]  subtree_sums,
    output logic        [N_MUL_ROW-1:0]             subtree_valid
);

    // ============================================================
    // Stage 0:Combinational compute leaf_mask & sign-extend partials
    // ============================================================
    //   leaf_mask[i] = sum(cut_after[0..i-1])
    //   leaf_mask[0] = 0
    //   Each cut_after[i]=1 increments the mask of all subsequent leaves by 1

    /* verilator lint_off UNOPTFLAT */   // leaf_mask is a prefix-sum chain, not a true combinational loop
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

    // leaf_mask computed via carry-chain (combinational running sum)
    assign leaf_mask[0] = 4'd0;
    genvar gm;
    generate
        for (gm = 1; gm < N_MUL_ROW; gm = gm + 1) begin : g_mask
            assign leaf_mask[gm] = leaf_mask[gm-1] + {3'd0, cut_after[gm-1]};
        end
    endgenerate

    // ============================================================
    // Stage 1: 8 nodes, each merges 2 leaves (no dump)
    // ============================================================
    //   Case 1: same mask    → is_single, val_l = val_r = vl + vr
    //   Case 2: different mask → not single, val_l = vl, val_r = vr

    logic signed [ACC_W-1:0] s1_val_l     [8];
    logic signed [ACC_W-1:0] s1_val_r     [8];
    logic [3:0]              s1_mask_l    [8];
    logic [3:0]              s1_mask_r    [8];
    logic [3:0]              s1_pos_l     [8];
    logic [3:0]              s1_pos_r     [8];
    logic                    s1_is_single [8];

    integer s1_i;
    /* verilator lint_off WIDTHTRUNC */  // pos = 2*i(+1), range 0..15, fits in 4 bits safely
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
    // Combine function shared logic (expanded inline / "local" style, iverilog-friendly)
    //   8 cases:
    //     Case A (L.mask_r == R.mask_l, boundary merge):
    //       A1: L and R both single → combine into single
    //       A2: L single, R not single → L merged into R's leftmost subtree
    //       A3: L not single, R single → R merged into L's rightmost subtree
    //       A4: both not single → boundary subtree fully contained, DUMP
    //     Case B (L.mask_r != R.mask_l, boundary):
    //       B1: both single → both sides may still extend, no dump
    //       B2: L single, R not single → R.val_l contained, dump R.val_l
    //       B3: L not single, R single → L.val_r contained, dump L.val_r
    //       B4: both not single → L.val_r and R.val_l both contained, 2 dumps
    // ============================================================
    // To run on iverilog (no struct-friendly support), each combine is
    // expressed with a group of signals producing:
    //   new state (7 fields) + up to 2 dumps (each with valid/pos/val)

    // ============================================================
    // Stage 2: 4 nodes, each merges 2 s1 nodes
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
            // Default clear
            s2_dmp1_valid[s2_i] = 1'b0;
            s2_dmp1_pos[s2_i]   = 4'd0;
            s2_dmp1_val[s2_i]   = '0;
            s2_dmp2_valid[s2_i] = 1'b0;
            s2_dmp2_pos[s2_i]   = 4'd0;
            s2_dmp2_val[s2_i]   = '0;

            if (s1_mask_r[2*s2_i] == s1_mask_l[2*s2_i+1]) begin
                // === Case A: boundary merge ===
                if (s1_is_single[2*s2_i] && s1_is_single[2*s2_i+1]) begin
                    // A1: both single → whole segment single
                    s2_val_l[s2_i]     = s1_val_l[2*s2_i] + s1_val_l[2*s2_i+1];
                    s2_val_r[s2_i]     = s1_val_l[2*s2_i] + s1_val_l[2*s2_i+1];
                    s2_mask_l[s2_i]    = s1_mask_l[2*s2_i];
                    s2_mask_r[s2_i]    = s1_mask_l[2*s2_i];
                    s2_pos_l[s2_i]     = s1_pos_r[2*s2_i+1];
                    s2_pos_r[s2_i]     = s1_pos_r[2*s2_i+1];
                    s2_is_single[s2_i] = 1'b1;
                end else if (s1_is_single[2*s2_i] && !s1_is_single[2*s2_i+1]) begin
                    // A2: L single → L merged into R's leftmost
                    s2_val_l[s2_i]     = s1_val_l[2*s2_i] + s1_val_l[2*s2_i+1];
                    s2_val_r[s2_i]     = s1_val_r[2*s2_i+1];
                    s2_mask_l[s2_i]    = s1_mask_l[2*s2_i];
                    s2_mask_r[s2_i]    = s1_mask_r[2*s2_i+1];
                    s2_pos_l[s2_i]     = s1_pos_l[2*s2_i+1];
                    s2_pos_r[s2_i]     = s1_pos_r[2*s2_i+1];
                    s2_is_single[s2_i] = 1'b0;
                end else if (!s1_is_single[2*s2_i] && s1_is_single[2*s2_i+1]) begin
                    // A3: R single → R merged into L's rightmost
                    s2_val_l[s2_i]     = s1_val_l[2*s2_i];
                    s2_val_r[s2_i]     = s1_val_r[2*s2_i] + s1_val_r[2*s2_i+1];
                    s2_mask_l[s2_i]    = s1_mask_l[2*s2_i];
                    s2_mask_r[s2_i]    = s1_mask_r[2*s2_i+1];
                    s2_pos_l[s2_i]     = s1_pos_l[2*s2_i];
                    s2_pos_r[s2_i]     = s1_pos_r[2*s2_i+1];
                    s2_is_single[s2_i] = 1'b0;
                end else begin
                    // A4: both not single → boundary subtree DUMP
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
                // === Case B: boundary differs ===
                if (s1_is_single[2*s2_i] && s1_is_single[2*s2_i+1]) begin
                    // B1: both single → both sides may still extend, no dump
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
                    // B4: both not single → 2 dumps
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
    // Stage 3: 2 nodes, each merges 2 s2 nodes (same 8-case)
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
    // Stage 4: 1 root node, merges 2 s3 nodes (same 8-case)
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
    // Final flush: after root, dump out root.val_l and root.val_r
    //   - if is_single, val_l == val_r, dump only once
    //   - if not single, dump twice (different positions)
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
    // Collect dumps from all stages into subtree_sums[16] / subtree_valid[16]
    //   Each position has at most one dump source (sub-tree end position is unique)
    //   Gathered via priority OR
    // ============================================================
    logic signed [ACC_W-1:0] sums_comb  [N_MUL_ROW];
    logic                    valid_comb [N_MUL_ROW];

    integer ic;
    integer ks2, ks3;

    always_comb begin
        // Default 0
        for (ic = 0; ic < N_MUL_ROW; ic = ic + 1) begin
            sums_comb[ic]  = '0;
            valid_comb[ic] = 1'b0;
        end

        // Stage 2 dumps (8 potential dumps from 4 nodes × 2 dump slots)
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
