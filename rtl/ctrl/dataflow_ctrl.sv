// =============================================================================
// dataflow_ctrl.sv — 全域 FSM,決定當下用哪個 dataflow + 控制 PE 起停
// =============================================================================
// Owner: Jacky Peng (彭俞凱) + 楊承豫 (per 2026-05-12 新分工:架構 & dataflow)
//
// === STUB ===
// Phase 1 Dense IP MVP 走 wrapper-driven(王柏弘 在 C++ 那邊驅動 PE 控制訊號),
// 這個 FSM 暫時保持 idle。Phase 2 TrIP 上線時才會把 FSM 邏輯填進來。
// =============================================================================


module dataflow_ctrl
    import trapezoid_pkg::*;
(
    input               clk,
    input               rst_n,
    input               start,
    input  logic [1:0]  dataflow_sel,
    output logic        done,

    // 給 PE Array (黃妍心 介面)
    output logic        pe_in_valid,
    output logic        pe_acc_clear,
    output logic        pe_acc_dump

    // TODO: 還要給 MFIU / Distribution Net / Memory Controller 訊號
);

    // stub: 永遠 idle
    assign done         = 1'b1;
    assign pe_in_valid  = 1'b0;
    assign pe_acc_clear = 1'b0;
    assign pe_acc_dump  = 1'b0;

    wire _unused = &{1'b0, clk, rst_n, start, dataflow_sel};

endmodule
