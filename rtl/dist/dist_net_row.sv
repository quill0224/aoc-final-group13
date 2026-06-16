// =============================================================================
// dist_net_row.sv — Per-PE-row A/B Distribution network
// =============================================================================
// NoC distribution network
// Paper: Trapezoid (ISCA'24) Fig 6「A/B Distribution」(Benes network)
//
// 依 MFIU 的 effectual_idx 把 a/b 路由到對的 multiplier:
//   out[m] = in[ effectual_idx[m] ]
// Dense IP 的 identity idx 讓它自動退化成 pass-through,所以不需 mode 分支。
//
// 拓樸:這就是一張 **crossbar**(non-blocking 16×16)。本檔用 behavioral select
//   寫(out[m]=in[idx[m]]),合成即為 mux-based crossbar。之後可換成顯式
//   Benes butterfly(同功能、switch 數較省),port 不變。
// Pipeline:組合 routing + 1 output register(DIST_STAGES=1)。
//
// 簡化:A/B 共用同一條 effectual_idx(Dense 下都 identity,等價)。若 TrIP
//   需要 A/B 分開路由,再加 b_idx port(對齊 MFIU 輸出)。
// =============================================================================

module dist_net_row
    import trapezoid_pkg::*;
(
    input  logic                                  clk,
    input  logic                                  rst_n,
    input  logic                                  en,
    input  logic                                  in_valid,

    input  logic [1:0]                            dataflow_sel,

    // ── raw a/b values ──
    input  logic signed [N_MUL_ROW-1:0][DATA_W-1:0] a_vec_in,
    input  logic signed [N_MUL_ROW-1:0][DATA_W-1:0] b_vec_in,

    // ── routing index from MFIU ──
    input  logic        [N_MUL_ROW-1:0][4:0]        effectual_idx,

    // ── routed a/b to the multiplier (registered) ──
    output logic signed [N_MUL_ROW-1:0][DATA_W-1:0] a_vec_out,
    output logic signed [N_MUL_ROW-1:0][DATA_W-1:0] b_vec_out,
    output logic                                    out_valid
);

    // ============================================================
    // packed → unpacked (works around iverilog packed-array variable-index limitation)
    // ============================================================
    logic signed [DATA_W-1:0] a_in_u [N_MUL_ROW];
    logic signed [DATA_W-1:0] b_in_u [N_MUL_ROW];
    logic [4:0]               idx_u  [N_MUL_ROW];

    genvar g;
    generate
        for (g = 0; g < N_MUL_ROW; g = g + 1) begin : g_unpack
            assign a_in_u[g] = a_vec_in[g];
            assign b_in_u[g] = b_vec_in[g];
            assign idx_u[g]  = effectual_idx[g];
        end
    endgenerate

    // ============================================================
    // Crossbar(behavioral select):out[m] = in[idx[m]]
    // ============================================================
    logic signed [DATA_W-1:0] a_out_c [N_MUL_ROW];
    logic signed [DATA_W-1:0] b_out_c [N_MUL_ROW];

    integer m;
    always_comb begin
        for (m = 0; m < N_MUL_ROW; m = m + 1) begin
            a_out_c[m] = a_in_u[idx_u[m][3:0]];   // use low 4 bits as index (0..15)
            b_out_c[m] = b_in_u[idx_u[m][3:0]];
        end
    end

    // ============================================================
    // Output register(DIST_STAGES = 1)
    // ============================================================
    logic signed [DATA_W-1:0] a_out_q [N_MUL_ROW];
    logic signed [DATA_W-1:0] b_out_q [N_MUL_ROW];

    integer r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (r = 0; r < N_MUL_ROW; r = r + 1) begin
                a_out_q[r] <= '0;
                b_out_q[r] <= '0;
            end
            out_valid <= 1'b0;
        end else if (en) begin
            for (r = 0; r < N_MUL_ROW; r = r + 1) begin
                a_out_q[r] <= a_out_c[r];
                b_out_q[r] <= b_out_c[r];
            end
            out_valid <= in_valid;
        end
    end

    // unpacked → packed output port
    genvar go;
    generate
        for (go = 0; go < N_MUL_ROW; go = go + 1) begin : g_pack
            assign a_vec_out[go] = a_out_q[go];
            assign b_vec_out[go] = b_out_q[go];
        end
    endgenerate

    // dataflow_sel reserved for future separate A/B routing; crossbar logic currently mode-agnostic
    wire _unused = &{1'b0, dataflow_sel};

endmodule
