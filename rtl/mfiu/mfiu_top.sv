// =============================================================================
// mfiu_top.sv — (legacy stub,已被 rtl/mfiu/mfiu_row.sv 取代)
// =============================================================================
// Owner: 楊承豫
//
// 舊的 global MFIU 空殼,只給舊 top.sv lint pass 用。完整 PE row 改用 per-row
// 的 mfiu_row.sv(對齊 paper Fig 6)。本檔保留只為不破壞舊 top.sv,可刪。
// =============================================================================


module mfiu_top
    import trapezoid_pkg::*;
(
    input  clk,
    input  rst_n
);

    // stub: 啥都不做
    wire _unused = &{1'b0, clk, rst_n};

endmodule
