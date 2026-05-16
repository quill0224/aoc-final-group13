// =============================================================================
// distribution_net.sv — A/B Distribution Network (Phase 1 Dense Pass-Through)
// =============================================================================
// Owner: 黃妍心 + QuillQ (per 2026-05-12 新分工: PE array + NoC + tree)
//        Phase 1 主寫: QuillQ
//
// === Phase 1 (Dense IP) === ✅ 本 PR 範圍
// 從 cache / global buffer 收 raw A grid 跟 B top row，
// identity pass-through 給 PE Array (黃妍心 介面)。
//
// Dense 模式下 (a, b) 跟 MAC 的對應是編譯時固定的 1-to-1 mapping，
// 不需要動態 routing，dist net 等同一條 wire (純組合 0 cycle latency)。
//
// === B 路徑為什麼是 single-row top（不是 full grid）===
// 對齊 Iris pe_array 的 B-chain forwarding (paper Fig 7 step ④):
//   - 只有 row 0 從外部拿 B (`b_vec_top`)
//   - Row 1..15 從上一條 row forward 進來 (pe_row 內 1-cycle latch)
//   - 外部 cache 只餵 row 0 的 16 個 B (128 bit/cycle)，**省 16× input bandwidth**
// 詳見 docs/interfaces.md §1 (Cache → PE Array 約定的 b_vec_top 形狀)
//
// === Phase 2 (TrIP) === 後續 PR (尚未啟動)
// 加 `dataflow_sel` + 從 MFIU 收 `effectual_idx` / `effectual_count`，
// TrIP 模式下用 16×16 crossbar 做動態 sparse routing
// (依 MFIU 算出的 intersection 位置動態 mux select)。
// 注意:per-row dist net 在 Phase 2 會搬進 pe_row 內 (對齊 paper Fig 6)，
// 屆時 B 也只 row 0 進入，符合 chain forwarding 原則。
// 詳細設計見:
//   - docs/interfaces.md §6  (Phase 2 介面契約)
//   - Obsidian [[Trapezoid Distribution Network]]  (概念 + 拓樸 + 練習)
//
// === 拓樸決策 === (2026-05-12 sync 鎖定)
// N=16 規模選 **crossbar** (不選 Benes):
//   - 控制簡單 (effectual_idx 直接當 mux select，0 cycle 純組合)
//   - 16 × 15 = 240 個 2-to-1 mux gate，面積可接受
//   - Benes 是 paper 128×128 規模才划算
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

    // ── Phase 1 input ──────────────────────────────────────────────────
    //    a_grid_in[r][m] : row r 內第 m 個 INT8 a (row-stationary, 全 16×16 grid)
    //    b_vec_in_top[m] : row 0 的第 m 個 INT8 b (single row, chain 自動 forward
    //                      給 row 1..15。Phase 2 sparse 也是 row 0 進 chain)
    //    layout 細節由 陳秉弘 設計 (top.sv 內 bank_rdata → grid 切片)
    input  wire signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0]   a_grid_in,
    input  wire signed [N_MUL_ROW-1:0][DATA_W-1:0]                 b_vec_in_top,

    // ── 輸出給 PE Array (對齊 pe_array 介面契約) ──────────────────────
    //    pe_a_grid  → pe_array.a_grid       (全 16×16, row-stationary)
    //    pe_b_top   → pe_array.b_vec_top    (只 row 0, B-chain forward 下去)
    output logic signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0]  pe_a_grid,
    output logic signed [N_MUL_ROW-1:0][DATA_W-1:0]                pe_b_top

    // ── Phase 2 預留 port (尚未啟用，等 MFIU + dataflow_ctrl 介面定下來) ──
    //    input  wire [1:0]                                       dataflow_sel
    //         從 dataflow_ctrl 來; MODE_DENSE_IP / MODE_TRIP / ...
    //    input  wire [N_PE_ROW-1:0][N_MUL_ROW-1:0][4:0]          effectual_idx
    //         從 MFIU 來 (per-row); 每個有效運算的「原 index 在哪裡」
    //    input  wire [N_PE_ROW-1:0][4:0]                         effectual_count
    //         從 MFIU 來 (per-row); 此 cycle 有幾個有效運算 (0~16)
);

    // =========================================================================
    // Phase 1 Dense IP — Identity Pass-Through
    // =========================================================================
    // A: 整個 16×16 grid 直接接通給 pe_array.a_grid (256 條獨立 wire, no mux)
    // B: row 0 的 16 個 b 接通給 pe_array.b_vec_top, 內部 B-chain 自動 forward
    //
    // Phase 2 會把這層改成 case 切 dataflow_sel:
    //   MODE_DENSE_IP → identity (這版邏輯)
    //   MODE_TRIP     → 走 effectual_idx crossbar
    //                   pe_a_grid[r][m] = (m < effectual_count[r])
    //                                     ? a_grid_in[r][effectual_idx[r][m]]
    //                                     : '0;
    // =========================================================================
    assign pe_a_grid = a_grid_in;
    assign pe_b_top  = b_vec_in_top;

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
