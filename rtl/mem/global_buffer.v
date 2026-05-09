// =============================================================================
// global_buffer.v — 16 個 1KB ADFP SRAM bank (16 KB total)
// =============================================================================
// Owner: 陳秉弘
//
// === STUB ===
// 真實版會用 ADFP 的 two-port SRAM hard macro 拼接。
// stub 用 reg array 讓功能模擬可以跑。
//
// 介面待 docs/interfaces.md §4 確認:
//   - 16 個獨立 read port 還是仲裁式 crossbar?
//   - 寫埠由誰仲裁 (DRAM-fill vs PE-writeback)
// =============================================================================


module global_buffer
    import trapezoid_pkg::*;
(
    input  wire                                clk,
    input  wire                                rst_n,

    output wire [N_BANK-1:0][BANK_W_BITS-1:0]  bank_rdata
    // TODO 陳秉弘: 完整 read/write port + bank arbitration
);

    // stub: 全 0
    assign bank_rdata = '0;
    wire _unused = &{1'b0, clk, rst_n};

endmodule
