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
// 拓樸:架構主打 **Benes network**(non-blocking 16×16,對齊 paper)。
//   本檔目前是功能等價的 gather stand-in(out[m]=in[idx[m]]),Benes 與
//   gather 對外行為相同,差在內部 switch 級數 / 面積。之後可換成真正的
//   Benes butterfly 實作,port 不變。
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

    // ── 原始 a/b 值 ──
    input  logic signed [N_MUL_ROW-1:0][DATA_W-1:0] a_vec_in,
    input  logic signed [N_MUL_ROW-1:0][DATA_W-1:0] b_vec_in,

    // ── 從 MFIU 來的 routing index ──
    input  logic        [N_MUL_ROW-1:0][4:0]        effectual_idx,

    // ── 給 multiplier 的 routing 後 a/b(registered)──
    output logic signed [N_MUL_ROW-1:0][DATA_W-1:0] a_vec_out,
    output logic signed [N_MUL_ROW-1:0][DATA_W-1:0] b_vec_out,
    output logic                                    out_valid
);

    // ============================================================
    // packed → unpacked(避開 iverilog packed-array 變數 index 限制)
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
    // Combinational gather:out[m] = in[idx[m]]
    // ============================================================
    logic signed [DATA_W-1:0] a_out_c [N_MUL_ROW];
    logic signed [DATA_W-1:0] b_out_c [N_MUL_ROW];

    integer m;
    always_comb begin
        for (m = 0; m < N_MUL_ROW; m = m + 1) begin
            a_out_c[m] = a_in_u[idx_u[m][3:0]];   // 取低 4 bit 當 index(0..15)
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

    // dataflow_sel 保留給未來 A/B 分開路由,目前 gather 邏輯 mode-agnostic
    wire _unused = &{1'b0, dataflow_sel};

endmodule
