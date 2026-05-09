// =============================================================================
// distribution_net.v — A/B 兩個 distribution network
// =============================================================================
// Owner: 施柏安
//
// === STUB ===
// 第一版輸出全 0,讓 PE Array 可以接得起來。
// =============================================================================


module distribution_net
    import trapezoid_pkg::*;
(
    input  wire                                                  clk,
    input  wire                                                  rst_n,

    // 輸出給 PE Array (黃妍心 介面)
    output wire signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0] pe_a_grid,
    output wire signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0] pe_b_grid

    // TODO 施柏安: 從 MFIU 收 intersection / prefix-sum index,從 SRAM 收 raw data,
    //              路由到正確的 PE 位置
);

    // stub: 全 0 輸出
    assign pe_a_grid = '0;
    assign pe_b_grid = '0;
    wire _unused = &{1'b0, clk, rst_n};

endmodule
