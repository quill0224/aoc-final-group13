// =============================================================================
// distribution_net.sv — A/B 兩個 distribution network
// =============================================================================
// Owner: 黃妍心 + QuillQ (per 2026-05-12 新分工:PE array + NoC + tree)
//
// === STUB ===
// 第一版輸出全 0,讓 PE Array 可以接得起來。
// Phase 1 (Dense IP) 真實邏輯就是 trivial pass-through(直接 a_grid_in → a_grid_out)。
// Phase 2 (TrIP) 才會做 Benes 動態 routing(接 MFIU 的 effectual_idx)。
// =============================================================================


module distribution_net
    import trapezoid_pkg::*;
(
    input                                                          clk,
    input                                                          rst_n,

    // 輸出給 PE Array (黃妍心 介面)
    output logic signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0]  pe_a_grid,
    output logic signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0]  pe_b_grid

    // TODO 黃妍心 + QuillQ: 從 MFIU 收 intersection / prefix-sum index,
    //                       從 SRAM 收 raw data,路由到正確的 PE 位置
);

    // stub: 全 0 輸出
    assign pe_a_grid = '0;
    assign pe_b_grid = '0;
    wire _unused = &{1'b0, clk, rst_n};

endmodule
