// =============================================================================
// SRAM_rtl.sv — TSMC N16ADFP 單埠 SRAM Macro 行為級模型與 Wrapper
// 規格: 128 Words x 64 Bits (1 KB)
// Macro Name: TS1N16ADFPCLLLVTA128X64M4SWSHOD
// =============================================================================

module SRAM_rtl (
    // 電源與測試腳 (模擬時忽略，合成時綁 0)
    input  logic        SLP,
    input  logic        DSLP,
    input  logic        SD,
    input  logic [1:0]  RCT,
    input  logic [1:0]  WTSEL,
    input  logic [2:0]  KP,
    output logic        PUDELAY,

    // 核心控制腳
    input  logic        CLK,   // 時鐘 (對應 CLKW/CLKR，單埠共用)
    input  logic        CEB,   // 晶片致能 (Chip Enable, Active-Low)
    input  logic        WEB,   // 寫入致能 (Write Enable, Active-Low)
    
    // 位址與資料
    input  logic [6:0]  A,     // 128 Words 位址 (對應 AA/AB)
    input  logic [63:0] D,     // 64-bit 寫入資料
    input  logic [63:0] BWEB,  // 64-bit 逐位元寫入遮罩 (Active-Low)
    output logic [63:0] Q      // 64-bit 讀出資料
);

    // -------------------------------------------------------------------------
    // 行為級記憶體陣列 (Behavioral Memory Array)
    // -------------------------------------------------------------------------
    logic [63:0] memory [0:127];
    logic [63:0] latched_q;

    assign PUDELAY = 1'b0;

    always_ff @(posedge CLK) begin
        if (~CEB) begin
            if (~WEB) begin
                // 寫入操作 (Write Operation)
                // 處理 Active-Low 的 Bit-Write Enable (BWEB)
                for (int i = 0; i < 64; i++) begin
                    if (~BWEB[i]) begin
                        memory[A][i] <= D[i];
                    end
                end
            end else begin
                // 讀取操作 (Read Operation) - 同步讀取 (1-cycle latency)
                latched_q <= memory[A];
            end
        end
    end

    // 輸出賦值
    always_comb begin
        Q = latched_q;
    end

endmodule
