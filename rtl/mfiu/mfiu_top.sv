// =============================================================================
// mfiu_top.sv — Multi-Fiber Intersection Unit (Bitmask AND + Prefix Sum)
// =============================================================================
// Owner: 劉偉健 (per 2026-05-12 新分工:model pruning + MFIU + 稀疏性判斷)
//
// === STUB ===
// 這份是空殼,讓 top.sv 可以 elaborate / lint pass。
// 真實邏輯由 劉偉健 之後填(Phase 2 TrIP 啟動時)。
// 改 port 之前,請先在 docs/interfaces.md 更新並通知 黃妍心 (top 對接者)。
// =============================================================================


module mfiu_top
    import trapezoid_pkg::*;
(
    input  clk,
    input  rst_n
    // TODO 劉偉健: bitmask in, intersection result out, prefix sum out
);

    // stub: 啥都不做
    wire _unused = &{1'b0, clk, rst_n};

endmodule
