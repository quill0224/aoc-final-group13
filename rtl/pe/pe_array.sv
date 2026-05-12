// =============================================================================
// pe_array.sv — paper Fig 5 對齊版:16 條 PE row + B 跨 row 垂直 forwarding
// =============================================================================
// Owner: 黃妍心
//
// === 對應 ISCA 2024 paper Fig 5 / Fig 7 step ④ ===
//   PE Array = 16 條 pe_row 上下疊起來。
//   B 從 row 0 進,每 cycle 往下傳一條 (透過 pe_row 的 1-cycle latch)。
//   A 是 row-stationary (per-row 從外部 register file 直接餵到 pe_row.a_vec)。
//
//   每 row 獨立輸出一個 INT32 C 元素 (dot product),由各 row 的
//   acc_dump 對齊控制 (上層 dataflow_ctrl 安排各 row 的 dump 時機)。
//
//   row 之間「不直接連 partial sum」(這跟 TPU systolic 不一樣)
//   不同 row 的 dot product 是各自完整的,沒有 row-to-row 累加。
//
// 控制訊號廣播:
//   in_valid / acc_clear / acc_dump 在第一版廣播給所有 row。
//   Phase 2 (TrIP) 改成 per-row signal 後,要把這些訊號改成 [N_PE_ROW] 寬度。
// =============================================================================

module pe_array
    import trapezoid_pkg::*;
(
    input                                                          clk,
    input                                                          rst_n,

    // ── 全域控制 ─────────────────────────────────────────────
    input  logic [1:0]                                             dataflow_sel,
    input                                                          in_valid,
    input                                                          acc_clear,
    input                                                          acc_dump,

    // ── A: row-stationary,16 條 row 各自 16 個 INT8 ────────
    //     由上層 (top.sv 內 register file) 提供
    input  logic signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0]  a_grid,

    // ── B: 從 cache 進 row 0,內部往下 forwarding ───────────
    //     第一版只有 1 條 B 進入 (Fig 4b TPU 風格);
    //     TrIP 多 fiber packing 時擴成 N_B_FIBER 條同時進入。
    input  logic signed [N_MUL_ROW-1:0][DATA_W-1:0]                b_vec_top,

    // ── C 輸出:per-row,每 row 1 個 INT32 dot product ──────
    output logic [N_PE_ROW-1:0]                                    c_valid,
    output logic signed [N_PE_ROW-1:0][ACC_W-1:0]                  c_out
);

    // ── B chain: row r 的 b 輸入 = 上一 row 的 b_vec_out ──
    //    row 0 的 b 輸入 = 外部 b_vec_top
    logic signed [N_PE_ROW:0][N_MUL_ROW-1:0][DATA_W-1:0] b_chain;
    logic        [N_PE_ROW:0]                            b_chain_valid;

    assign b_chain[0]       = b_vec_top;
    assign b_chain_valid[0] = in_valid;

    // ── 16 條 PE row,B 串成垂直 chain ──
    genvar r;
    generate
        for (r = 0; r < N_PE_ROW; r = r + 1) begin : g_row
            pe_row u_row (
                .clk         (clk),
                .rst_n       (rst_n),
                .in_valid    (b_chain_valid[r]),    // 第一版:沿 B chain 帶下來
                .acc_clear   (acc_clear),           // 第一版:全 row 廣播
                .acc_dump    (acc_dump),            // 第一版:全 row 廣播
                .a_vec       (a_grid[r]),
                .b_vec_in    (b_chain[r]),
                .b_vec_out   (b_chain[r+1]),
                .b_valid_out (b_chain_valid[r+1]),
                .c_valid     (c_valid[r]),
                .c_out       (c_out[r])
            );
        end
    endgenerate

    // dataflow_sel 第一版只接著、不用;Phase 2 才會切 per-row 控制
    wire _unused = &{1'b0, dataflow_sel, b_chain_valid[N_PE_ROW]};

endmodule
