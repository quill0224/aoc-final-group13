// =============================================================================
// mfiu_adapter_mf.sv — Multi-Fiber MFIU adapter (4×4 packing)
// =============================================================================
// Owner: NoC(QuillQ) — 多 fiber 路線的 MFIU 包裝；給 dist_net_row_trip 餵料
// Paper: Trapezoid (ISCA'24) Fig 11/12, Multi-Fiber Intersection Unit
//
// === 跟 Iris 單 fiber 版 mfiu_adapter.sv 的差別 ===
//   單 fiber 版:把楊的 mfiu 核心設成 1×1,只吐單一 effectual_idx
//   本檔多 fiber:把核心設成 N_A_FIBER × N_B_FIBER (4×4),吐三條
//                a_row_sel / b_col_sel / k_sel + lane_valid,直接接
//                dist_net_row_trip(2D gather)。
//   → 兩版並存:dataflow_ctrl / 整合時選用哪顆。
//
// === 做的事 ===
//   1. instantiate 楊的 mfiu.v 核心(NUM_ROWS=4, NUM_COLS=4, K_BITS=16, LANES=16)
//      → 掃 4×4×16 候選,把 effectual (r,c,k) 壓進 16 lane,overflow 時拉旗標
//   2. 把核心的 flat bus 輸出轉成 dist_net_row_trip 要的多維 port
//   3. 延 MFIU_STAGES 拍,對齊 pe_row datapath
//
// === 上游需要配合(2D 餵料)===
//   a_bitmask / b_bitmask 現在是「4 條 fiber 各 16 bit」= 64 bit(不是單 16)。
//   pe_row / buffer 要同時供 4 條 A fiber + 4 條 B fiber 的 bitmask 與 value。
//   value 那條(a_values/b_values)直接餵給 dist_net_row_trip。
//
// === overflow 註記 ===
//   一拍 4×4×16 候選最多遠超 16 lane;核心壓滿 16 後拉 overflow_o。
//   replay(把沒裝完的下一拍補)屬上游 ctrl 的事,本檔只透傳 overflow。
// =============================================================================

module mfiu_adapter_mf
    import trapezoid_pkg::*;
#(
    parameter int NUM_A_FIBER = N_A_FIBER,   // 4
    parameter int NUM_B_FIBER = N_B_FIBER,   // 4
    parameter int K_SLOTS     = BITMASK_W,   // 16
    parameter int LANES       = N_MUL_ROW,   // 16
    // ── derived ──
    parameter int ROW_IDX_W = (NUM_A_FIBER > 1) ? $clog2(NUM_A_FIBER) : 1,  // 2
    parameter int COL_IDX_W = (NUM_B_FIBER > 1) ? $clog2(NUM_B_FIBER) : 1,  // 2
    parameter int K_IDX_W   = (K_SLOTS     > 1) ? $clog2(K_SLOTS)     : 1,  // 4
    parameter int CNT_W     = $clog2(LANES + 1)                             // 5
)(
    input  logic clk,
    input  logic rst_n,
    input  logic en,
    input  logic in_valid,

    // ── 4 條 fiber 各 K_SLOTS bit 的 bitmask(上游餵)──
    input  logic [NUM_A_FIBER*K_SLOTS-1:0] a_bitmask,
    input  logic [NUM_B_FIBER*K_SLOTS-1:0] b_bitmask,

    // ── 給 dist_net_row_trip 的多維 routing metadata(registered)──
    output logic [LANES-1:0]                  lane_valid,
    output logic [LANES-1:0][ROW_IDX_W-1:0]   a_row_sel,
    output logic [LANES-1:0][COL_IDX_W-1:0]   b_col_sel,
    output logic [LANES-1:0][K_IDX_W-1:0]     k_sel,
    output logic [CNT_W-1:0]                  match_count,
    output logic                              overflow,
    output logic                              meta_valid
);

    // ── intersection 核心:楊 mfiu.v,設成 4×4 × K_SLOTS ──
    logic [LANES-1:0]           core_vld;
    logic [LANES*ROW_IDX_W-1:0] core_row;
    logic [LANES*COL_IDX_W-1:0] core_col;
    logic [LANES*K_IDX_W-1:0]   core_k;
    logic [CNT_W-1:0]           core_cnt;
    logic                       core_ovf;

    mfiu #(
        .NUM_ROWS (NUM_A_FIBER),
        .NUM_COLS (NUM_B_FIBER),
        .K_BITS   (K_SLOTS),
        .LANES    (LANES)
    ) u_core (
        .a_mask_i      (a_bitmask),
        .b_mask_i      (b_bitmask),
        .lane_valid_o  (core_vld),
        .a_row_sel_o   (core_row),
        .b_col_sel_o   (core_col),
        .k_sel_o       (core_k),
        .match_count_o (core_cnt),
        .overflow_o    (core_ovf)
    );

    // ── 延 MFIU_STAGES 拍(對齊 datapath)──
    logic [LANES-1:0]           vld_pipe [MFIU_STAGES];
    logic [LANES*ROW_IDX_W-1:0] row_pipe [MFIU_STAGES];
    logic [LANES*COL_IDX_W-1:0] col_pipe [MFIU_STAGES];
    logic [LANES*K_IDX_W-1:0]   k_pipe   [MFIU_STAGES];
    logic [CNT_W-1:0]           cnt_pipe [MFIU_STAGES];
    logic                       ovf_pipe [MFIU_STAGES];
    logic [MFIU_STAGES-1:0]     mvld_pipe;

    integer s;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (s = 0; s < MFIU_STAGES; s = s + 1) begin
                vld_pipe[s] <= '0; row_pipe[s] <= '0; col_pipe[s] <= '0;
                k_pipe[s]   <= '0; cnt_pipe[s] <= '0; ovf_pipe[s] <= '0;
            end
            mvld_pipe <= '0;
        end else if (en) begin
            vld_pipe[0] <= core_vld; row_pipe[0] <= core_row; col_pipe[0] <= core_col;
            k_pipe[0]   <= core_k;   cnt_pipe[0] <= core_cnt; ovf_pipe[0] <= core_ovf;
            for (s = 1; s < MFIU_STAGES; s = s + 1) begin
                vld_pipe[s] <= vld_pipe[s-1]; row_pipe[s] <= row_pipe[s-1];
                col_pipe[s] <= col_pipe[s-1]; k_pipe[s]   <= k_pipe[s-1];
                cnt_pipe[s] <= cnt_pipe[s-1]; ovf_pipe[s] <= ovf_pipe[s-1];
            end
            mvld_pipe <= {mvld_pipe[MFIU_STAGES-2:0], in_valid};
        end
    end

    // ── flat bus → 多維 port(最後一級)──
    genvar g;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : g_unpack
            assign a_row_sel[g] = row_pipe[MFIU_STAGES-1][g*ROW_IDX_W +: ROW_IDX_W];
            assign b_col_sel[g] = col_pipe[MFIU_STAGES-1][g*COL_IDX_W +: COL_IDX_W];
            assign k_sel[g]     = k_pipe  [MFIU_STAGES-1][g*K_IDX_W   +: K_IDX_W];
        end
    endgenerate
    assign lane_valid  = vld_pipe[MFIU_STAGES-1];
    assign match_count = cnt_pipe[MFIU_STAGES-1];
    assign overflow    = ovf_pipe[MFIU_STAGES-1];
    assign meta_valid  = mvld_pipe[MFIU_STAGES-1];

endmodule
