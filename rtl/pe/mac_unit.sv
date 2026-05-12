// =============================================================================
// mac_unit.sv — INT8 × INT8 → INT16 multiplier (registered output)
// =============================================================================
// Owner: 黃妍心
// 用在: pe_row.sv 內,16 個並排
//
// === 重要架構決定 (對齊 ISCA 2024 paper Fig 6) ===
// mac_unit 只做「乘法」,不做累加。
// 累加 (acc) 與化簡 (reduction tree) 在 pe_row 內處理:
//   16 個 mul → merge-reduction tree (radix-16) → row-level accumulator
// 這跟 paper Fig 6 一致;之前版本把 acc 放在 mac_unit 是錯的,
// 那種設計 (per-mul acc) 在 TrIP 模式下無法支援動態 (a_row, b_col) 重新映射。
//
// Pipeline: 1 cycle latency
//   product 在下個 cycle 出現在輸出。500 MHz @ ADFP 對 INT8×INT8 輕鬆。
//
// 不會處理的事:
//   - 累加 (在 pe_row 的 acc register)
//   - dataflow mode 切換 (那是 dataflow_ctrl 的事)
//   - 輸出 valid / 對齊 (由 pe_row 的 stage register 處理)
// =============================================================================

module mac_unit (
    input                       clk,
    input                       rst_n,
    input                       en,         // 此 cycle 把 a*b 寫進 product
    input  signed [7:0]         a,          // INT8 operand A
    input  signed [7:0]         b,          // INT8 operand B
    output logic signed [15:0]  product     // INT16 = a * b,registered
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)    product <= 16'sd0;
        else if (en)   product <= a * b;
        // else: 保持 (downstream stage 會用 valid pipe 判斷有效)
    end

endmodule
