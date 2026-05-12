// =============================================================================
// global_buffer.sv — 16 個 1KB ADFP SRAM bank (16 KB total)
// =============================================================================
// Owner: 待認領 (原規劃 陳秉弘,2026-05-12 新分工未明列)
//
// === STUB ===
// 真實版會用 ADFP 的 two-port SRAM hard macro 拼接。
// stub 用 logic array 讓功能模擬可以跑。
//
// 介面待 docs/interfaces.md §4 確認:
//   - 16 個獨立 read port 還是仲裁式 crossbar?
//   - 寫埠由誰仲裁 (DRAM-fill vs PE-writeback)
// =============================================================================


module global_buffer
    import trapezoid_pkg::*;
(
    input                                       clk,
    input                                       rst_n,

    output logic [N_BANK-1:0][BANK_W_BITS-1:0]  bank_rdata
    // TODO: 完整 read/write port + bank arbitration
);

    // stub: 全 0
    assign bank_rdata = '0;
    wire _unused = &{1'b0, clk, rst_n};

endmodule
