// =============================================================================
// mfiu_row.sv — Per-PE-row Multi-Fiber Intersection Unit
// =============================================================================
// TrIP 交集介面;multi-fiber 核心見 mfiu.v / mfiu_trip.sv
//
// 對應 paper Fig 11/12:吃 A/B bitmask,算出 multiplier 該算哪些 effectual 運算,
// 以及結果怎麼路由 / 切 sub-tree。
//
// 本檔已實作(可獨立驗證):
//   - intersection : eff = a_bitmask & b_bitmask
//   - prefix-sum 壓縮 : effectual_idx[j] = 第 j 個 effectual lane 的原始位置
//   - effectual_count : effectual lane 總數
//   Dense IP(bitmask 全 1)時壓縮退化成 identity,count=16。
//
// 留給 multi-fiber TrIP(見 mfiu_trip.sv):
//   - cut_after  : 4×4 fiber packing 時,哪些 lane 屬於同一 C → sub-tree 邊界
//                  (目前單一 sub-tree,cut=0)
//   - out_addr   : 每個 sub-tree 結果的 C column(目前 Dense:單一 C 在 cur_n)
//   - 下游 lane 歸零:lane >= effectual_count 的 mul 輸入要歸零(整合時做)
//
// Pipeline:metadata 延 MFIU_STAGES 拍輸出,對齊 pe_row 內被延遲的 A/B 值。
// =============================================================================

module mfiu_row
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

    // ── intersection + prefix-sum compaction (combinational) ──
    logic [N_MUL_ROW-1:0] eff_vec;
    assign eff_vec = a_bitmask & b_bitmask;

    logic [4:0] idx_arr [N_MUL_ROW];   // compacted original positions
    logic [4:0] cnt_c;
    integer k, pos;
    always_comb begin
        for (k = 0; k < N_MUL_ROW; k = k + 1) idx_arr[k] = 5'd0;
        pos = 0;
        for (k = 0; k < N_MUL_ROW; k = k + 1) begin
            if (eff_vec[k]) begin
                idx_arr[pos] = k[4:0];
                pos = pos + 1;
            end
        end
        cnt_c = pos[4:0];
    end

    // ── pack idx + Dense-correct cut_after / out_addr ──
    logic [N_MUL_ROW-1:0][4:0]              idx_comb;
    logic [N_MUL_ROW-1:0][LOCAL_BUF_AW-1:0] addr_comb;
    genvar g;
    generate
        for (g = 0; g < N_MUL_ROW; g = g + 1) begin : g_meta
            assign idx_comb[g]  = idx_arr[g];
            assign addr_comb[g] = (g == N_MUL_ROW-1) ? cur_n : {LOCAL_BUF_AW{1'b0}};
        end
    endgenerate

    logic [N_MUL_ROW-2:0] cut_comb;
    assign cut_comb = '0;   // single sub-tree; multi-fiber cut scheme see mfiu_trip.sv

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

    // dataflow_sel reserved for the multi-fiber TrIP body
    wire _unused = &{1'b0, dataflow_sel};

endmodule
