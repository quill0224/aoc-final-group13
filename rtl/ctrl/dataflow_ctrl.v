// =============================================================================
// dataflow_ctrl.v — 全域 FSM,決定當下用哪個 dataflow + 控制 PE 起停
// =============================================================================
// Owner: ★ 待認領 ★ (建議 彭俞凱 兼,因為他做 MFIU 最清楚 mode 對應)
//
// === STUB ===
// 這是 proposal 沒分到任何人的 FSM,但它沒寫的話整個 system 不會動。
// 第一週討論時務必把它認下來。
// =============================================================================


module dataflow_ctrl
    import trapezoid_pkg::*;
(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [1:0]  dataflow_sel,
    output wire        done,

    // 給 PE Array (黃妍心 介面)
    output wire        pe_in_valid,
    output wire        pe_acc_clear,
    output wire        pe_acc_dump

    // TODO: 還要給 MFIU / Distribution Net / Memory Controller 訊號
);

    // stub: 永遠 idle
    assign done         = 1'b1;
    assign pe_in_valid  = 1'b0;
    assign pe_acc_clear = 1'b0;
    assign pe_acc_dump  = 1'b0;

    wire _unused = &{1'b0, clk, rst_n, start, dataflow_sel};

endmodule
