// =============================================================================
// mac_unit.sv — Signed INT8 × INT8 registered multiplier for PE row
// =============================================================================
// 功能:
//   計算 signed INT8 運算元 a、b 的乘積,結果暫存於 signed INT16 product。
//   本模組只做 multiplication,不含 accumulation:product 為單一 A/B pair
//   的 partial product。
//
// 資料路徑位置:
//   上游:operand dispatch / distribution stage —— 送入配對完成的 A/B
//        運算元;en 由上層 valid pipeline 產生,表示本拍輸入有效。
//   本級:PE row 乘法 stage,16 顆並排,同拍產生 16 個 partial product。
//   下游:reduction tree 做分組加總;local buffer 做後續累加與暫存;
//        output valid 的最終對齊由上層 pipeline 管理。
//
// 介面:
//   clk      : 時脈,上升緣觸發
//   rst_n    : 非同步 reset,active-low;reset 時 product 清 0
//   en       : output register enable;en=1 寫入 a*b,en=0 保持原值
//   a, b     : signed [7:0],二補數 INT8
//   product  : signed [15:0],registered partial product
//
// 時序:
//   latency    : 1 cycle ; product 對應 input_valid 延遲 1 拍
//   throughput : en 恆為 1 時每拍更新一筆乘積;en=0 時 product 保持上一筆,
//                下游須依 valid pipe 判斷該值是否有效
//
// 數值範圍:
//   signed INT8 範圍 [-128, 127];INT8 × INT8 完整乘積範圍
//   [-16256, +16384],可完整表示於 signed INT16,
//   故不需截斷、飽和或溢位處理。
// =============================================================================

module mac_unit (
    input                       clk,
    input                       rst_n,
    input                       en,         // when set, write a*b into product this cycle
    input  signed [7:0]         a,          // INT8 operand A
    input  signed [7:0]         b,          // INT8 operand B
    output logic signed [15:0]  product     // INT16 = a * b, registered
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)    product <= 16'sd0;
        else if (en)   product <= a * b;
        // else: hold (downstream stage uses the valid pipe to determine validity)
    end

endmodule
