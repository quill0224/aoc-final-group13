// =============================================================================
// pe_row.sv — paper Fig 6 對齊版:16 mul + radix-16 tree + acc + B-forwarding
// =============================================================================
// Owner: 黃妍心
//
// === 跟 ISCA 2024 paper Fig 6 / Fig 7 對應 ===
//   一條 PE row 內含:
//     [1] mul array       — 16 個 mac_unit (黃妍心,這個檔負責的核心)
//     [2] merge-reduction tree (radix-16,per-row,this 檔 instantiate;
//                               module 在 rtl/dist/merge_tree_radix16.sv,黃妍心 + QuillQ co-own)
//     [3] accumulator     — 1 個 INT32 register,跨 K-tile 累加 tree 結果 (黃妍心)
//     [4] B forwarding    — 把 b_vec 延 1 cycle 給下一條 row (Fig 7 ④,黃妍心)
//
//   未實作 (Phase 2 才加):
//     [5] MFIU            — 在 mul 前面,per-row,給 TrIP 用
//     [6] A/B Distribution — Benes,per-row,給 TrIP 用
//     [7] Local Buf       — 4-bank scatter buffer,給 TrIP/TrGT/TrGS 用
//
// Pipeline (Dense IP, 7 stages,對齊 PPTX p.13):
//   S1: latch b_vec_in / a_vec  (input register)
//   S2: mul                     (mac_unit registered output)
//   S3: tree stage 1            (16 → 8)
//   S4: tree stage 2            (8 → 4)
//   S5: tree stage 3            (4 → 2)
//   S6: tree stage 4            (2 → 1)
//   S7: acc add + c_out         (accumulator register)
//
// 介面契約:
//   in_valid   : a_vec / b_vec_in 此 cycle 有效要送進 mul
//   acc_clear  : 清零 acc (新 dot product 開始前用)
//   acc_dump   : 此 cycle 把 acc 倒給 c_out (K-tile 結束時拉高)
//                注意:acc_dump 必須對齊 tree 輸出,即從 in_valid 拉高那拍算起
//                第 7 拍才拉高 (上層 dataflow_ctrl 控)
// =============================================================================

module pe_row
    import trapezoid_pkg::*;
#(
    parameter int N_MUL = N_MUL_ROW   // 16
) (
    input                                         clk,
    input                                         rst_n,

    // ── 控制 ──────────────────────────────────────────
    input                                         in_valid,    // a/b 有效
    input                                         acc_clear,   // 清零 accumulator
    input                                         acc_dump,    // 此 cycle 倒 c_out

    // ── A: row-stationary,從上層 register file 來 ───
    input  logic signed [N_MUL-1:0][DATA_W-1:0]   a_vec,

    // ── B: 從上方 row 進,延 1 cycle 給下方 row ─────
    input  logic signed [N_MUL-1:0][DATA_W-1:0]   b_vec_in,
    output logic signed [N_MUL-1:0][DATA_W-1:0]   b_vec_out,
    output logic                                  b_valid_out,

    // ── C 輸出:1 個 INT32 dot product per row ───────
    output logic                                  c_valid,
    output logic signed [ACC_W-1:0]               c_out
);

    // =====================================================================
    // S1: B / A 進來先打一拍對齊
    // =====================================================================
    logic signed [N_MUL-1:0][DATA_W-1:0] a_q, b_q;
    logic                                v_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_q <= '0;
            b_q <= '0;
            v_q <= 1'b0;
        end else begin
            a_q <= a_vec;
            b_q <= b_vec_in;
            v_q <= in_valid;
        end
    end

    // =====================================================================
    // S2: 16 個 mul (mac_unit 輸出 registered)
    // =====================================================================
    logic signed [N_MUL-1:0][PROD_W-1:0] partials;

    genvar i;
    generate
        for (i = 0; i < N_MUL; i = i + 1) begin : g_mul
            mac_unit u_mul (
                .clk     (clk),
                .rst_n   (rst_n),
                .en      (v_q),
                .a       (a_q[i]),
                .b       (b_q[i]),
                .product (partials[i])
            );
        end
    endgenerate

    // mul 輸出對應的 valid (delay 1 cycle 跟 partials 對齊)
    logic v_mul;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) v_mul <= 1'b0;
        else        v_mul <= v_q;
    end

    // =====================================================================
    // S3-S6: merge-reduction tree (4 stages)
    //   merge_tree_radix16 module 在 rtl/dist/(黃妍心 + QuillQ co-own)。
    //   pe_row 負責 instantiate + 餵 partials。
    // =====================================================================
    logic signed [ACC_W-1:0] tree_sum;

    merge_tree_radix16 u_tree (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (1'b1),
        .partials (partials),
        .sum      (tree_sum)
    );

    // 跟 tree 對齊的 valid pipeline (S3 → S6,共 4 stage)
    logic [3:0] v_tree_pipe;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) v_tree_pipe <= 4'b0;
        else        v_tree_pipe <= {v_tree_pipe[2:0], v_mul};
    end
    wire tree_valid = v_tree_pipe[3];

    // =====================================================================
    // S7: accumulator + C 輸出
    //   acc_clear / acc_dump 必須由上層 dataflow_ctrl 對齊到此拍 (即 in_valid
    //   拉起後第 7 拍才能拉 acc_dump)。
    //
    //   ⚠️ 時序鐵則 — Phase 2 dataflow_ctrl 實作者必看 ⚠️
    //   下面 c_out 那行有個 `(acc_dump && tree_valid)` 的 conditional,意思是
    //   「dump 那拍如果剛好 tree 還在送最後一個 partial,就把它也合進去」。
    //   這個 fallback **只在 acc_dump 嚴格對齊到「最後一筆 in_valid 後第 7 拍」
    //   時才正確**。FSM 對齊錯一拍會發生:
    //     - 早 1 拍 dump : 會吃到 stale acc (少加最後一筆 partial)
    //     - 晚 1 拍 dump : tree_valid 已 deassert,c_out 沒問題,但 acc register
    //                      會把同一筆 partial 多加一次 (因為 tree_valid 那拍
    //                      已經把 acc 累上去了),下一個 dot product 起點髒
    //
    //   Phase 2 FSM 實作建議:
    //     (a) 嚴格遵守「in_valid 末拍 + 6 → 拉 acc_dump」固定 latency,或
    //     (b) 寧可多 1 拍 drain (在 acc_dump 前等 tree_valid 拉低再拉 dump),
    //         讓 conditional 永遠走 false branch,行為退化成單純 c_out <= acc。
    //   現在 tb_pe_array.sv 是按 (a) 寫的,所以 broadcast mode 沒事;
    //   per-row variable-length sub-dot-product (TrIP) 上線後請優先考慮 (b)。
    // =====================================================================
    logic signed [ACC_W-1:0] acc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc     <= 32'sd0;
            c_valid <= 1'b0;
            c_out   <= 32'sd0;
        end else begin
            // acc 更新:clear > add (clear 優先)
            if (acc_clear) begin
                acc <= 32'sd0;
            end else if (tree_valid) begin
                acc <= acc + tree_sum;
            end

            // c_out:dump 那拍把 acc (含此拍 tree 貢獻) 倒出
            // 注意 (acc_dump && tree_valid) 的時序依賴,見上方 ⚠️ 區塊
            c_valid <= acc_dump;
            c_out   <= (acc_dump && tree_valid) ? (acc + tree_sum) : acc;
        end
    end

    // =====================================================================
    // B forwarding: 把 b_vec_in 延 1 cycle 給下一條 row (Fig 7 ④)
    // 控制 valid 一起延一拍
    // =====================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_vec_out   <= '0;
            b_valid_out <= 1'b0;
        end else begin
            b_vec_out   <= b_vec_in;
            b_valid_out <= in_valid;
        end
    end

endmodule
