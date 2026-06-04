// =============================================================================
// local_buffer_row.sv — Per-PE-row scatter / accumulate output buffer
// =============================================================================
// Owner: 黃妍心
// Paper: Trapezoid (ISCA'24) §III.B「banked local buffer」/ Fig 6「Local Buf」
//
// 接 merge tree 的多個 sub-tree 結果,scatter-accumulate 進對應 C column,
// 支援跨 K-tile 累加。每拍最多 16 個 sub-tree 各寫一個 C(out_addr 指定),
// 假設同拍 valid 的 out_addr 互異(不同 sub-tree → 不同 C,自然成立)。
//
// 控制:clear 清整塊;acc_en scatter-accumulate;dump_en/dump_addr registered
// 讀出。K-tile loop:每拍 acc_en 累加,結束拉 dump_en。
//
// 容量 LOCAL_BUF_DEPTH=512(VGG-16 max N),INT32 → 2 KB。
// 此處 behavioral array;synth 換 ADFP SRAM macro(512×45 或 4×128×32,
// 見 docs/memory-mapping),4-bank 拆 16 寫埠。
// =============================================================================

module local_buffer_row
    import trapezoid_pkg::*;
(
    input  logic                                       clk,
    input  logic                                       rst_n,
    input  logic                                       en,        // pipeline 推進

    // ── 從 merge-reduction tree 來 ──
    input  logic signed [N_MUL_ROW-1:0][ACC_W-1:0]     subtree_sums,
    input  logic        [N_MUL_ROW-1:0]                subtree_valid,

    // ── 每 sub-tree position → 寫進 buffer 的哪個 C column ──
    //    (Dense IP: out_addr[15] = current output column n)
    input  logic        [N_MUL_ROW-1:0][LOCAL_BUF_AW-1:0] out_addr,

    // ── 控制 ──
    input  logic                                       clear,     // 清零整個 buffer
    input  logic                                       acc_en,    // 此 cycle scatter-accumulate
    input  logic                                       dump_en,   // 此 cycle 讀出 C
    input  logic        [LOCAL_BUF_AW-1:0]             dump_addr, // 讀哪個 C column

    // ── 輸出(registered)──
    output logic                                       c_valid,
    output logic signed [ACC_W-1:0]                    c_out
);

    // ============================================================
    // 把 packed 輸入轉成 unpacked(避開 iverilog packed-array 變數
    // index 在 always_ff 內的限制,沿用 sliced tree 的安全 pattern)
    // ============================================================
    logic signed [ACC_W-1:0]      sums_u [N_MUL_ROW];
    logic                         val_u  [N_MUL_ROW];
    logic [LOCAL_BUF_AW-1:0]      addr_u [N_MUL_ROW];

    genvar g;
    generate
        for (g = 0; g < N_MUL_ROW; g = g + 1) begin : g_unpack
            assign sums_u[g] = subtree_sums[g];
            assign val_u[g]  = subtree_valid[g];
            assign addr_u[g] = out_addr[g];
        end
    endgenerate

    // ============================================================
    // Buffer storage(behavioral;synth 換 SRAM macro)
    // ============================================================
    logic signed [ACC_W-1:0] mem [LOCAL_BUF_DEPTH];

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < LOCAL_BUF_DEPTH; i = i + 1)
                mem[i] <= '0;
            c_valid <= 1'b0;
            c_out   <= '0;
        end else if (en) begin
            // ── clear:清零整個 buffer(新 output tile 開始)──
            if (clear) begin
                for (i = 0; i < LOCAL_BUF_DEPTH; i = i + 1)
                    mem[i] <= '0;
            end
            // ── scatter-accumulate:每個 valid sub-tree 累加進對應 C column ──
            else if (acc_en) begin
                for (i = 0; i < N_MUL_ROW; i = i + 1) begin
                    if (val_u[i])
                        mem[addr_u[i]] <= mem[addr_u[i]] + sums_u[i];
                end
            end

            // ── dump:registered read(讀此 cycle 之前的 mem 值)──
            //    K-tile loop 安排:最後一拍 accumulate 完,下一拍才 dump,
            //    所以 dump 讀到的是「含最後一個 K-tile」的最終值。
            c_valid <= dump_en;
            c_out   <= mem[dump_addr];
        end
    end

endmodule
