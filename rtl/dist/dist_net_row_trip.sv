// =============================================================================
// dist_net_row_trip.sv — Per-PE-row TrIP multi-fiber A/B Distribution network
// =============================================================================
// Owner: NoC(QuillQ + 黃妍心)
// Paper : Trapezoid (ISCA'24) Fig 6「A/B Distribution」, multi-fiber TrIP path
//
// === 這個檔在做什麼 (整合版,對齊 paper multi-fiber) ===
// 把 MFIU 算出的「有效 (row,col,k) 索引」拿來,從 fiber value buffer 把對的
// a / b 值 gather 到對的 multiplier lane:
//
//     a_lane[l] = a_values[ a_row_sel[l] ][ k_sel[l] ]
//     b_lane[l] = b_values[ b_col_sel[l] ][ k_sel[l] ]
//
// 這是「2D gather」: 每條 lane 用 (fiber, k) 兩個座標去取值,對應 4×4 fiber
// packing — 一排 16 lane 可以同時服務多個輸出 (r,c)。
//
// === 跟 Dense 版 dist_net_row.sv 的差別 ===
//   Dense 版 : 單一 effectual_idx,1D gather  out[m]=in[idx[m]] (a/b 共用 idx)
//   本檔TrIP : 三條 sel(row/col/k),2D gather (a 用 row、b 用 col、共用 k)
//   → 兩個 module 並存:Dense IP 走 dist_net_row,TrIP 走本檔 (dataflow_ctrl 選)
//
// === 來源 ===
// 演算法移植自 楊承豫 FPGA MVP 的 trip_distribution_network.v
//   (原檔: 純組合、Verilog-2001、裸參數、LANES=4 的 2×2 MVP)
// 本檔的整合化改寫:
//   (1) 改成 SystemVerilog + import trapezoid_pkg (型別/參數 single source)
//   (2) scale 到 spec: N_A_FIBER=4 / N_B_FIBER=4 / BITMASK_W=16 / LANES=16
//   (3) 補 1 級 output register (DIST_STAGES=1) + in_valid→out_valid handshake
//       → 對齊 pe_row 的 pipeline (見 trapezoid_pkg PE_ROW_STAGES)
//   (4) iverilog packed-array 變數 index 限制 → 先攤成 unpacked flat array
//
// === 跟 楊 MFIU 介面對齊 (pe_row 接線時的轉換, Iris wrap 用) ===
// 楊 mfiu 輸出是「flat packed bus」,本檔輸入是「SV 多維 packed array」:
//   楊 a_row_sel_o[LANES*ROW_IDX_W-1:0]  →  本檔 a_row_sel[LANES][ROW_IDX_W]
//   楊 b_col_sel_o[LANES*COL_IDX_W-1:0]  →  本檔 b_col_sel[LANES][COL_IDX_W]
//   楊 k_sel_o    [LANES*K_IDX_W-1:0]    →  本檔 k_sel    [LANES][K_IDX_W]
//   楊 lane_valid_o[LANES-1:0]           →  本檔 lane_valid[LANES]
// (兩者 bit 對 bit 相同,只是打包形狀不同;接線時 lane l 取 [l*W +: W] 即可)
// =============================================================================

module dist_net_row_trip
    import trapezoid_pkg::*;
#(
    parameter int NUM_A_FIBER = N_A_FIBER,    // 4  (同時 pack 的 A 列數)
    parameter int NUM_B_FIBER = N_B_FIBER,    // 4  (同時 stream 的 B 行數)
    parameter int K_SLOTS     = BITMASK_W,    // 16 (每條 fiber 的 k slot 數)
    parameter int LANES       = N_MUL_ROW,    // 16 (= 一個 PE row 的乘法器數)
    // ── derived (勿從外部 override) ──
    parameter int ROW_IDX_W   = (NUM_A_FIBER > 1) ? $clog2(NUM_A_FIBER) : 1,  // 2
    parameter int COL_IDX_W   = (NUM_B_FIBER > 1) ? $clog2(NUM_B_FIBER) : 1,  // 2
    parameter int K_IDX_W     = (K_SLOTS     > 1) ? $clog2(K_SLOTS)     : 1,  // 4
    parameter int A_DEPTH     = NUM_A_FIBER * K_SLOTS,                        // 64
    parameter int B_DEPTH     = NUM_B_FIBER * K_SLOTS                         // 64
)(
    input  logic clk,
    input  logic rst_n,
    input  logic en,
    input  logic in_valid,

    // ── fiber value buffer (2D: [fiber][k]) ──
    input  logic signed [NUM_A_FIBER-1:0][K_SLOTS-1:0][DATA_W-1:0] a_values,
    input  logic signed [NUM_B_FIBER-1:0][K_SLOTS-1:0][DATA_W-1:0] b_values,

    // ── 從 MFIU 來的 per-lane routing metadata ──
    input  logic [LANES-1:0]                  lane_valid,
    input  logic [LANES-1:0][ROW_IDX_W-1:0]   a_row_sel,
    input  logic [LANES-1:0][COL_IDX_W-1:0]   b_col_sel,
    input  logic [LANES-1:0][K_IDX_W-1:0]     k_sel,

    // ── gather 後給 multiplier 的 a/b (registered) ──
    output logic signed [LANES-1:0][DATA_W-1:0] a_lane_out,
    output logic signed [LANES-1:0][DATA_W-1:0] b_lane_out,
    output logic [LANES-1:0]                     lane_valid_out,
    output logic                                 out_valid
);

    // ========================================================================
    // 0) 攤平 packed → unpacked flat array
    //    iverilog 不允許「變數」index packed array 維度;unpacked 才行。
    //    a_values[fiber][k]  →  a_flat[ fiber*K_SLOTS + k ]
    // ========================================================================
    logic signed [DATA_W-1:0] a_flat [A_DEPTH];   // 64 個 a 值
    logic signed [DATA_W-1:0] b_flat [B_DEPTH];   // 64 個 b 值

    genvar gr, gk;
    generate
        for (gr = 0; gr < NUM_A_FIBER; gr = gr + 1) begin : g_a_fiber
            for (gk = 0; gk < K_SLOTS; gk = gk + 1) begin : g_a_k
                assign a_flat[gr*K_SLOTS + gk] = a_values[gr][gk];
            end
        end
        for (gr = 0; gr < NUM_B_FIBER; gr = gr + 1) begin : g_b_fiber
            for (gk = 0; gk < K_SLOTS; gk = gk + 1) begin : g_b_k
                assign b_flat[gr*K_SLOTS + gk] = b_values[gr][gk];
            end
        end
    endgenerate

    // metadata 也攤成 unpacked (同樣為了變數 index 安全)
    logic [ROW_IDX_W-1:0] row_u [LANES];
    logic [COL_IDX_W-1:0] col_u [LANES];
    logic [K_IDX_W-1:0]   k_u   [LANES];
    logic                 vld_u [LANES];

    genvar gl;
    generate
        for (gl = 0; gl < LANES; gl = gl + 1) begin : g_meta_unpack
            assign row_u[gl] = a_row_sel[gl];
            assign col_u[gl] = b_col_sel[gl];
            assign k_u[gl]   = k_sel[gl];
            assign vld_u[gl] = lane_valid[gl];
        end
    endgenerate

    // ========================================================================
    // 1) Combinational 2D gather (= 一排 16 顆 64-to-1 mux,a/b 各一組)
    //    a_slot = row*K_SLOTS + k  (把 (fiber,k) 攤成 flat offset)
    //    無效 lane 直接吐 0 → 下游乘法器算 0,不污染 reduction
    //    廣播天然支援: 多條 lane 指同一 slot 沒問題 (TrGT stretch)
    // ========================================================================
    logic signed [DATA_W-1:0] a_lane_c [LANES];
    logic signed [DATA_W-1:0] b_lane_c [LANES];

    integer l;
    always_comb begin
        for (l = 0; l < LANES; l = l + 1) begin
            if (vld_u[l]) begin
                a_lane_c[l] = a_flat[ row_u[l]*K_SLOTS + k_u[l] ];
                b_lane_c[l] = b_flat[ col_u[l]*K_SLOTS + k_u[l] ];
            end else begin
                a_lane_c[l] = '0;
                b_lane_c[l] = '0;
            end
        end
    end

    // ========================================================================
    // 2) Output register (DIST_STAGES = 1) + valid pipeline
    //    對齊 trapezoid_pkg::DIST_STAGES;斷開 64-to-1 mux 的長組合路徑
    // ========================================================================
    logic signed [DATA_W-1:0] a_lane_q [LANES];
    logic signed [DATA_W-1:0] b_lane_q [LANES];
    logic [LANES-1:0]         vld_q;

    integer r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (r = 0; r < LANES; r = r + 1) begin
                a_lane_q[r] <= '0;
                b_lane_q[r] <= '0;
            end
            vld_q     <= '0;
            out_valid <= 1'b0;
        end else if (en) begin
            for (r = 0; r < LANES; r = r + 1) begin
                a_lane_q[r] <= a_lane_c[r];
                b_lane_q[r] <= b_lane_c[r];
            end
            vld_q     <= lane_valid;   // gather 後的 per-lane valid 一起打拍
            out_valid <= in_valid;
        end
    end

    // unpacked → packed output port
    genvar go;
    generate
        for (go = 0; go < LANES; go = go + 1) begin : g_pack_out
            assign a_lane_out[go]     = a_lane_q[go];
            assign b_lane_out[go]     = b_lane_q[go];
            assign lane_valid_out[go] = vld_q[go];
        end
    endgenerate

    // synthesis-time sanity: 本檔假設 DIST_STAGES=1;若 pkg 改了要回來補 stage
    initial begin
        if (DIST_STAGES != 1)
            $warning("dist_net_row_trip: DIST_STAGES=%0d but this module hard-codes 1 register stage", DIST_STAGES);
    end

endmodule
