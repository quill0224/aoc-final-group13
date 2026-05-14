// =============================================================================
// distribution_net.sv — A/B Distribution Network (Phase 1 Dense Pass-Through)
// =============================================================================
// Owner: 黃妍心 + QuillQ (per 2026-05-12 新分工: PE array + NoC + tree)
//        Phase 1 主寫: QuillQ
//
// === Phase 1 (Dense IP) === ✅ 本 PR 範圍
// 從 cache / global buffer 收 raw a_grid / b_grid，
// identity pass-through 給 PE Array (黃妍心 介面)。
// Dense 模式下 (a, b) 跟 MAC 的對應是編譯時固定的 1-to-1 mapping，
// 不需要動態 routing，所以 dist net 等同一條 wire (純組合 0 cycle latency)。
//
// === Phase 2 (TrIP) === 後續 PR (尚未啟動)
// 加 `dataflow_sel` + 從 MFIU 收 `effectual_idx` / `effectual_count`，
// TrIP 模式下用 16×16 crossbar 做動態 sparse routing
// (依 MFIU 算出的 intersection 位置動態 mux select)。
// 詳細設計見:
//   - docs/interfaces.md §6  (Phase 2 介面契約)
//   - Obsidian [[Trapezoid Distribution Network]]  (概念 + 拓樸 + 練習)
//
// === 拓樸決策 === (2026-05-12 sync 鎖定)
// N=16 規模選 **crossbar** (不選 Benes):
//   - 控制簡單 (effectual_idx 直接當 mux select，0 cycle 純組合)
//   - 16 × 15 = 240 個 2-to-1 mux gate，面積可接受
//   - Benes 是 paper 128×128 規模才划算 (省 mux gate 但控制邏輯複雜)
//
// === Pipeline 深度 === (2026-05-12 sync 鎖定)
// Phase 1 純組合 (0 cycle)。Phase 2 預期仍 0 cycle，
// 計算 delay 吃 mul stage 的 setup time (對齊 trapezoid_pkg::TRIP_STAGES = 9)。
// 如果 synth 後 critical path 過 2 ns @ 500 MHz，再切 1 stage register。
// =============================================================================

module distribution_net
    import trapezoid_pkg::*;
(
    input                                                          clk,
    input                                                          rst_n,

    // ── Phase 1 input: 從 cache / global buffer 收 raw a/b grid ──
    //    a_grid_in[r][m] : row r 內第 m 個 INT8 a (row-stationary)
    //    b_grid_in[r][m] : row r 內第 m 個 INT8 b
    //                      (Phase 1 從 cache 直接餵 16 條 row;
    //                       Phase 2 改走 B-chain vertical forwarding)
    //    layout 細節由 陳秉弘 設計 (top.sv 內 bank_rdata → grid 切片)
    input  wire signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0]   a_grid_in,
    input  wire signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0]   b_grid_in,

    // ── 輸出給 PE Array (黃妍心 介面，port name 維持原契約) ──
    output logic signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0]  pe_a_grid,
    output logic signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0]  pe_b_grid

    // ── Phase 2 預留 port (尚未啟用，等 MFIU + dataflow_ctrl 介面定下來) ──
    //    input  wire [1:0]                                       dataflow_sel
    //         從 dataflow_ctrl 來; MODE_DENSE_IP (2'b00) / MODE_TRIP (2'b01) / ...
    //    input  wire [N_PE_ROW-1:0][N_MUL_ROW-1:0][4:0]          effectual_idx
    //         從 MFIU 來 (per-row); 每個有效運算的「原 index 在哪裡」
    //    input  wire [N_PE_ROW-1:0][4:0]                         effectual_count
    //         從 MFIU 來 (per-row); 此 cycle 有幾個有效運算 (0~16)
);

    // =========================================================================
    // Phase 1 Dense IP — Identity Pass-Through
    // =========================================================================
    // Dense 模式下，a/b 跟 MAC 的對應是編譯時固定的 1-to-1:
    //   MAC#m  永遠拿  a[m], b[m]
    // 不需要動態 routing，dist net 等同一條 wire。
    //
    // 等價於展開:
    //   for (r = 0; r < 16; r++)
    //     for (m = 0; m < 16; m++) begin
    //       pe_a_grid[r][m] = a_grid_in[r][m];
    //       pe_b_grid[r][m] = b_grid_in[r][m];
    //     end
    // 用 packed array 整體賦值，synth 會展開成 256 條獨立 wire (no mux)。
    //
    // Phase 2 會把這層改成 case 切 dataflow_sel:
    //   MODE_DENSE_IP → identity (這版邏輯)
    //   MODE_TRIP     → 走 effectual_idx crossbar
    //                   pe_a_grid[r][m] = (m < effectual_count[r])
    //                                     ? a_grid_in[r][effectual_idx[r][m]]
    //                                     : '0;
    // =========================================================================
    assign pe_a_grid = a_grid_in;
    assign pe_b_grid = b_grid_in;

    // ─────────────────────────────────────────────────────────────────────────
    // UNUSED 訊號抑制 (給 Verilator lint 用)
    //   Phase 1 純組合不用 clk / rst_n，但保留 port 是為了 Phase 2 加 register
    //   (例如 critical path 過 2ns 要切 1 stage) 時不用改 module 介面。
    //
    //   ⚠️ 注意:第一個字不要寫 "Verilator"，否則 Verilator 會誤把整行當 pragma
    //   解析 (e.g. `// verilator lint_off X`)，看到不認識的 token 會 error。
    // ─────────────────────────────────────────────────────────────────────────
    wire _unused = &{1'b0, clk, rst_n};

endmodule
