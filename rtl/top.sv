// =============================================================================
// top.sv — Trapezoid-Lite 系統 Top Level (Phase 1 Dense IP MVP)
// =============================================================================
// Owner: 黃妍心
//
// === Phase 1 (Dense IP MVP) 範圍 ===
//   只實例化:
//     - dataflow_ctrl   (FSM stub)
//     - global_buffer   (cache stub) → 給 b_vec_top 跟 a_grid 餵料
//     - pe_array        (real,paper Fig 5 對齊版,B 跨 row 垂直 forwarding)
//
//   未實例化 (Phase 2 才加,且按 paper 是 per-row 在 pe_row 內):
//     - MFIU            (Multi-Fiber Intersection Unit) × 16
//     - A/B Distribution Network (Benes) × 16
//     - per-row Local Buf (4-bank, 16-word-wide) × 16
//
// 對外介面 (跟 王柏弘 的 Verilator wrapper 對接):
//     - control regs:  start / done / mode (dataflow_sel)
//     - DRAM stub:     單條 read/write port (位寬待 王柏弘 確認)
// =============================================================================

module top
    import trapezoid_pkg::*;
(
    input                       clk,
    input                       rst_n,

    // ── 控制 (跟 Verilator wrapper 對接) ──
    input                       start,
    output logic                done,
    input  logic [1:0]          dataflow_sel,

    // ── DRAM 介面 (簡化版,等王柏弘確認) ──
    output logic                dram_req_valid,
    output logic [31:0]         dram_req_addr,
    output logic                dram_req_we,
    output logic [63:0]         dram_req_wdata,
    input  logic                dram_resp_valid,
    input  logic [63:0]         dram_resp_rdata
);

    // ===========================================================
    // 內部訊號
    // ===========================================================

    // dataflow_ctrl → pe_array
    logic pe_in_valid;
    logic pe_acc_clear;
    logic pe_acc_dump;

    // global_buffer 對外讀 (TODO 陳秉弘:接到 a_grid / b_vec_top 餵料)
    logic [N_BANK-1:0][BANK_W_BITS-1:0] bank_rdata;

    // 第一版:a_grid / b_vec_top 都從 cache 出 (尚未接,先 0)
    logic signed [N_PE_ROW-1:0][N_MUL_ROW-1:0][DATA_W-1:0] a_grid;
    logic signed [N_MUL_ROW-1:0][DATA_W-1:0]               b_vec_top;
    assign a_grid    = '0;   // TODO 陳秉弘 + 黃妍心:從 bank_rdata 切片
    assign b_vec_top = '0;   // TODO 陳秉弘 + 黃妍心:從 bank_rdata 切片

    // pe_array → 寫回 cache / DRAM
    logic [N_PE_ROW-1:0]                  c_valid;
    logic signed [N_PE_ROW-1:0][ACC_W-1:0] c_out;

    // ===========================================================
    // Dataflow Controller (待認領 — orphan FSM,Phase 1 stub)
    // ===========================================================
    dataflow_ctrl u_dataflow_ctrl (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .dataflow_sel   (dataflow_sel),
        .done           (done),
        .pe_in_valid    (pe_in_valid),
        .pe_acc_clear   (pe_acc_clear),
        .pe_acc_dump    (pe_acc_dump)
    );

    // ===========================================================
    // Global Buffer / Cache (陳秉弘,Phase 1 stub)
    // ===========================================================
    global_buffer u_global_buffer (
        .clk            (clk),
        .rst_n          (rst_n),
        .bank_rdata     (bank_rdata)
    );

    // ===========================================================
    // PE Array (黃妍心 — paper Fig 5 對齊,B 跨 row 垂直 forwarding)
    // ===========================================================
    pe_array u_pe_array (
        .clk            (clk),
        .rst_n          (rst_n),
        .dataflow_sel   (dataflow_sel),
        .in_valid       (pe_in_valid),
        .acc_clear      (pe_acc_clear),
        .acc_dump       (pe_acc_dump),
        .a_grid         (a_grid),
        .b_vec_top      (b_vec_top),
        .c_valid        (c_valid),
        .c_out          (c_out)
    );

    // ===========================================================
    // Phase 2 預留:per-row MFIU + A/B Distribution + Local Buf
    // 將會在 pe_row 內部 instantiate (per-row),不會在 top.sv 加 module。
    // 目前 rtl/mfiu/ 與 rtl/dist/ 內的 stub 是「Phase 2 接收區」,
    // 還沒在 top 接線 — 不算 lint dead code (Verilator --top-module 不會掃)。
    // ===========================================================

    // ===========================================================
    // DRAM 介面:Phase 1 dummy
    // ===========================================================
    assign dram_req_valid = 1'b0;
    assign dram_req_addr  = 32'd0;
    assign dram_req_we    = 1'b0;
    assign dram_req_wdata = 64'd0;

    // 暫時把沒接到的 c_out / dram resp 標 unused (Verilator 不警告)
    wire _unused = &{1'b0, c_valid, c_out, bank_rdata,
                     dram_resp_valid, dram_resp_rdata};

endmodule
