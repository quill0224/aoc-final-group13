// =============================================================================
// merge_tree_radix16.v — 16-input pipelined adder tree (radix-16, 4 stages)
// =============================================================================
// === 模組 OWNER: 施柏安 (per proposal §6.2: Merge-Reduction Tree) ===
//
// 註記 (2026-05-09 黃妍心):
//   這份是 黃妍心 起草的「pipeline 對接用 skeleton」,目的是讓 pe_row
//   能 lint pass 並驗 7-stage 時序。**模組 body 屬於 施柏安**,他可以:
//     - 完全保留 (若這份功能正確,後續維護 / 第二版 TrIP slicing 由他主導)
//     - 重寫 (照他自己的 micro-architecture,只要 port 不變)
//     - 加 testbench (`sim/tb_merge_tree.sv` 由 施柏安 寫,黃妍心 不寫)
//   如果 port 要改,先在群組講 + 同步到 docs/interfaces.md (黃妍心 合作)。
//
// 在 pe_row 內 instantiate (per-row,16 棵,對齊 paper Fig 6,不是 global)。
//
// 行為:
//   16 個 INT16 partial → 4 stages → 1 個 INT32 sum
//   每 stage 是 pairwise add 並打 register。
//   16→8→4→2→1,每層位寬 +1 bit,最後 sign-extend 到 INT32。
//
// Pipeline: 4 cycles latency
//   stage1: partials_in (16 × INT16)         → s1[0..7]   (8 × INT17)
//   stage2: s1                                → s2[0..3]  (4 × INT18)
//   stage3: s2                                → s3[0..1]  (2 × INT19)
//   stage4: s3                                → sum       (1 × INT32, sign-ext)
//
// 第二版 (TrIP) TODO (施柏安):
//   論文 Fig 6 提到 tree 可被切成 N 個 sub-tree (radix-2/4/8) 平行產生 N 個 C 元素,
//   給 TrIP 動態 packing 用。第一版只支援單一 16→1 模式 (Dense IP)。
// =============================================================================

module merge_tree_radix16
    import trapezoid_pkg::*;
(
    input  wire                                    clk,
    input  wire                                    rst_n,
    input  wire                                    en,         // 1 → 推進 pipeline
    input  wire signed [N_MUL_ROW-1:0][PROD_W-1:0] partials,   // 16 × INT16
    output reg  signed [ACC_W-1:0]                 sum         // INT32
);

    // ── stage 1: 16 → 8 (位寬 PROD_W+1 = 17) ──
    reg signed [PROD_W:0]   s1_0, s1_1, s1_2, s1_3, s1_4, s1_5, s1_6, s1_7;

    // ── stage 2: 8 → 4 (位寬 PROD_W+2 = 18) ──
    reg signed [PROD_W+1:0] s2_0, s2_1, s2_2, s2_3;

    // ── stage 3: 4 → 2 (位寬 PROD_W+3 = 19) ──
    reg signed [PROD_W+2:0] s3_0, s3_1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {s1_0, s1_1, s1_2, s1_3, s1_4, s1_5, s1_6, s1_7} <= '0;
            {s2_0, s2_1, s2_2, s2_3} <= '0;
            {s3_0, s3_1} <= '0;
            sum  <= 32'sd0;
        end else if (en) begin
            // stage 1: pairwise add 16 → 8
            s1_0 <= partials[0]  + partials[1];
            s1_1 <= partials[2]  + partials[3];
            s1_2 <= partials[4]  + partials[5];
            s1_3 <= partials[6]  + partials[7];
            s1_4 <= partials[8]  + partials[9];
            s1_5 <= partials[10] + partials[11];
            s1_6 <= partials[12] + partials[13];
            s1_7 <= partials[14] + partials[15];

            // stage 2: 8 → 4
            s2_0 <= s1_0 + s1_1;
            s2_1 <= s1_2 + s1_3;
            s2_2 <= s1_4 + s1_5;
            s2_3 <= s1_6 + s1_7;

            // stage 3: 4 → 2
            s3_0 <= s2_0 + s2_1;
            s3_1 <= s2_2 + s2_3;

            // stage 4: 2 → 1, sign-extend INT19 → INT32
            sum  <= {{(ACC_W-(PROD_W+3)){s3_0[PROD_W+2]}}, s3_0}
                  + {{(ACC_W-(PROD_W+3)){s3_1[PROD_W+2]}}, s3_1};
        end
    end

endmodule
