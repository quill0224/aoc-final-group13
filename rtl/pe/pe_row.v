// =============================================================================
// pe_row.v — paper Fig 6 對齊版:16 mul + radix-16 tree + acc + B-forwarding
// =============================================================================
// Owner: 黃妍心
//
// === 跟 ISCA 2024 paper Fig 6 / Fig 7 對應 ===
//   一條 PE row 內含:
//     [1] mul array       — 16 個 mac_unit (黃妍心 owner,這個檔負責的核心)
//     [2] merge-reduction tree (radix-16,per-row,this 檔 instantiate;
//                               module body owner = 施柏安,在 rtl/dist/merge_tree_radix16.v)
//     [3] accumulator     — 1 個 INT32 register,跨 K-tile 累加 tree 結果 (黃妍心)
//     [4] B forwarding    — 把 b_vec 延 1 cycle 給下一條 row (Fig 7 ④,黃妍心)
//
//   未實作 (Phase 2 才加):
//     [5] MFIU            — 在 mul 前面,per-row,給 TrIP 用 (彭俞凱)
//     [6] A/B Distribution — Benes,per-row,給 TrIP 用 (施柏安)
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
    input  wire                                clk,
    input  wire                                rst_n,

    // ── 控制 ──────────────────────────────────────────
    input  wire                                in_valid,    // a/b 有效
    input  wire                                acc_clear,   // 清零 accumulator
    input  wire                                acc_dump,    // 此 cycle 倒 c_out

    // ── A: row-stationary,從上層 register file 來 ───
    input  wire signed [N_MUL-1:0][DATA_W-1:0] a_vec,

    // ── B: 從上方 row 進,延 1 cycle 給下方 row ─────
    input  wire signed [N_MUL-1:0][DATA_W-1:0] b_vec_in,
    output reg  signed [N_MUL-1:0][DATA_W-1:0] b_vec_out,
    output reg                                 b_valid_out,

    // ── C 輸出:1 個 INT32 dot product per row ───────
    output reg                                 c_valid,
    output reg  signed [ACC_W-1:0]             c_out
);

    // =====================================================================
    // S1: B / A 進來先打一拍對齊
    // =====================================================================
    reg signed [N_MUL-1:0][DATA_W-1:0] a_q, b_q;
    reg                                v_q;

    always @(posedge clk or negedge rst_n) begin
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
    wire signed [N_MUL-1:0][PROD_W-1:0] partials;

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
    reg v_mul;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) v_mul <= 1'b0;
        else        v_mul <= v_q;
    end

    // =====================================================================
    // S3-S6: merge-reduction tree (4 stages)
    //   merge_tree_radix16 module body owner = 施柏安 (rtl/dist/);
    //   pe_row 只負責 instantiate + 餵 partials,不擁有 tree micro-arch。
    // =====================================================================
    wire signed [ACC_W-1:0] tree_sum;

    merge_tree_radix16 u_tree (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (1'b1),
        .partials (partials),
        .sum      (tree_sum)
    );

    // 跟 tree 對齊的 valid pipeline (S3 → S6,共 4 stage)
    reg [3:0] v_tree_pipe;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) v_tree_pipe <= 4'b0;
        else        v_tree_pipe <= {v_tree_pipe[2:0], v_mul};
    end
    wire tree_valid = v_tree_pipe[3];

    // =====================================================================
    // S7: accumulator + C 輸出
    //   acc_clear / acc_dump 必須由上層 dataflow_ctrl 對齊到此拍 (即 in_valid
    //   拉起後第 7 拍才能拉 acc_dump)。
    // =====================================================================
    reg signed [ACC_W-1:0] acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc     <= 32'sd0;
            c_valid <= 1'b0;
            c_out   <= 32'sd0;
        end else begin
            // acc 更新:clear > add (clear 優先,跟原版 mac_unit 行為一致)
            if (acc_clear) begin
                acc <= 32'sd0;
            end else if (tree_valid) begin
                acc <= acc + tree_sum;
            end

            // c_out:dump 那拍把 acc (含此拍 tree 貢獻) 倒出
            c_valid <= acc_dump;
            c_out   <= (acc_dump && tree_valid) ? (acc + tree_sum) : acc;
        end
    end

    // =====================================================================
    // B forwarding: 把 b_vec_in 延 1 cycle 給下一條 row (Fig 7 ④)
    // 控制 valid 一起延一拍
    // =====================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_vec_out   <= '0;
            b_valid_out <= 1'b0;
        end else begin
            b_vec_out   <= b_vec_in;
            b_valid_out <= in_valid;
        end
    end

endmodule
