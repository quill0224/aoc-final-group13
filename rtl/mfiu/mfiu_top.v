// =============================================================================
// mfiu_top.v — Multi-Fiber Intersection Unit (Bitmask AND + Prefix Sum)
// =============================================================================
// Owner: 彭俞凱 (Leader)
//
// === STUB ===
// 這份是空殼,讓 top.v 可以 elaborate / lint pass。
// 彭俞凱 之後會把實際邏輯填進來。
// 改 port 之前,請先在 docs/interfaces.md 更新並通知 黃妍心 (top 對接者)
// =============================================================================


module mfiu_top
    import trapezoid_pkg::*;
(
    input  wire clk,
    input  wire rst_n
    // TODO 彭俞凱: bitmask in, intersection result out, prefix sum out
);

    // stub: 啥都不做
    wire _unused = &{1'b0, clk, rst_n};

endmodule
