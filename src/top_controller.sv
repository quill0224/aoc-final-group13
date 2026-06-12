`include "AXI/AXI_define.svh"
`include "ASIC_define.svh"

// =============================================================================
// top_controller.sv — Trapezoid-Lite ASIC Top FSM Controller (FINAL)
//
// 支援模式 : StandardIP (MODE_STD_IP=2'b00), TrIP (MODE_TRIP=2'b01)
// 資料封包 : [bitmask 16b][NZ_values 128b] = 144b per fiber
// AXI 寬度 : 32b/beat (AXI_DATA_BITS=32), GLB 128b/beat
//
// MKN 迴圈順序 (外 → 內):
// M : output spatial tile (最大 49 tiles, 7×7 for 224→7 after pooling)
// K : input ch × filter spatial tile (最大 288 = 3×3×32)
// N : output channel tile (最大 32)
//
// A (ifmap / weight) 重用 : 每個 M tile 只載入一次，跨所有 K×N 迭代重用
// B (activation / filter) : 每個 N tile 都重新載入
//
// v1 初始版
// v2 tile_total underflow fix, lint
// v3 mc_start comb, asic_en sync, PE_en explicit, assertion fix
// v4 DMA_mode typed, GLB zero-pad, tile_total guard, q[2] assert
// v5 MKN 三計數器, S9 拆為 S9_NK / S9b_M, A-reuse path
// v6 DMA_done deadlock fix: dma_b_done_flag / dma_wb_done_flag
// v7 (FINAL)
// - comp_C_len 從 MMIO 傳入，不再固定 256
// - FSM 狀態順序修正：S8→S10→S9b（先寫回再更新位址）
// - GLB_ADDR_BITS 18-bit (256KB)
// - mc_* 訊號在 S4 就穩定，S5 才送 mc_start
// - DMA_en 修正：S3 等待期間不讓 DMA 重新觸發
// - dma_b_done_flag 清除時機修正（在進入 S4 的 cycle 清除）
// - 所有輸出在 rst 時有明確初始值
// - watchdog 計數器寬度加寬至 16-bit 防溢出
// - 移除 C_TILE_BYTES localparama，改用 shadow register comp_C_len
// =============================================================================

module top_controller (
//--------------------------------------------------------------------------
// System
//--------------------------------------------------------------------------
input logic clk,
input logic rst,

// asic_en: level signal, 來自 AXI-Lite MMIO (可能跨 clock domain)
// 內部會做兩級同步。Host 必須在 asic_done 拉高後降下 asic_en
// 才能開始下一次運算。
input logic asic_en,

// asic_done: level，在 S11_DONE 期間保持高，直到 asic_en 降下
output logic asic_done,

//--------------------------------------------------------------------------
// MMIO — DRAM Base Addresses
//--------------------------------------------------------------------------
input logic [`AXI_ADDR_BITS-1:0] A_fiber_base_addr,
input logic [`AXI_ADDR_BITS-1:0] B_fiber_base_addr,
input logic [`AXI_ADDR_BITS-1:0] C_tensor_base_addr,

//--------------------------------------------------------------------------
// MMIO — GLB Base Addresses (18-bit, 256KB 空間)
//--------------------------------------------------------------------------
input logic [`GLB_ADDR_BITS-1:0] GLB_A_base_addr,
input logic [`GLB_ADDR_BITS-1:0] GLB_B_base_addr,
input logic [`GLB_ADDR_BITS-1:0] GLB_C_base_addr,

//--------------------------------------------------------------------------
// MMIO — Tiling & Control Parameters
// 所有長度單位：bytes，必須 4B 對齊（AXI 32b 寬度）
//--------------------------------------------------------------------------
input logic [31:0] comp_A_len_in, // A tile 壓縮後 byte 長度
input logic [31:0] comp_B_len_in, // B tile 壓縮後 byte 長度
input logic [31:0] comp_C_len_in, // C tile 寫回 byte 長度
input logic [`N_CNT_BITS-1:0] N_tiles_in, // output channel tiles
input logic [`K_CNT_BITS-1:0] K_tiles_in, // input ch × filter tiles
input logic [`M_CNT_BITS-1:0] M_tiles_in, // output spatial tiles
input logic [`PKT_CNT_BITS-1:0] packet_count_in, // 每個 tile 的封包數
input logic [1:0] operation_mode_in,

//--------------------------------------------------------------------------
// MMIO — PE Mapping Parameters
//--------------------------------------------------------------------------
input logic [3:0] e,
input logic [2:0] p,
input logic [2:0] q, // q[2] 必須為 0（assertion 驗證）
input logic [2:0] r, // reserved，tied off
input logic [2:0] t, // reserved，tied off

//--------------------------------------------------------------------------
// DMA Interface
//
// DMA_done 行為假設：1-cycle pulse。
// Controller 內部用 flag 鎖存，避免 pulse 被錯過。
// DMA 模組必須在 DMA_en 降下後才能重新接受新的傳輸請求，
// 不能在 DMA_en 持續高電位時自動觸發第二次傳輸。
//--------------------------------------------------------------------------
output logic DMA_en,
output logic [1:0] DMA_mode,
output logic [`AXI_ADDR_BITS-1:0] DMA_DRAM_ADDR,
output logic [`GLB_ADDR_BITS-1:0] DMA_GLB_ADDR,
output logic [31:0] DMA_len,
input logic DMA_done,

//--------------------------------------------------------------------------
// Memory Controller (MC) Interface
//
// mc_start : combinational pulse，S5_MC_DISPATCH 期間剛好一個 cycle 高電位
// MC 必須在這個 cycle 的上升沿鎖存所有 mc_* 訊號
// mc_mode : 在 S4 就穩定，MC 可提前讀取
// mc_glb_base_A/B : GLB 讀取起始位址，在 S4 穩定
// mc_packet_count : 本次 tile 的封包數，在 S4 穩定
// k_done : MC 派發完 K_tile 條 fiber 後發出的 1-cycle pulse
//--------------------------------------------------------------------------
output logic mc_start,
output logic [1:0] mc_mode,
output logic [`GLB_ADDR_BITS-1:0] mc_glb_base_A,
output logic [`GLB_ADDR_BITS-1:0] mc_glb_base_B,
output logic [`PKT_CNT_BITS-1:0] mc_packet_count,
input logic k_done,

//--------------------------------------------------------------------------
// PE Array Interface
//
// global_mode : 運算模式廣播，從 S4 開始有效
// global_flush : combinational pulse，S7_FLUSH 期間一個 cycle 高電位
// PE Array 收到後解鎖 Local Buffer 輸出
// 確認 PE spec：1 cycle 足以排空 pipeline
// PE_en : S4~S8 期間全部拉高，其餘拉低
// PE_config : [10:9]=mode [8:5]=e [4:2]=p [1:0]=q[1:0]
// PEA_A_ready : A_FIFO 未滿，可接收新資料（由 MC 直接用，Controller 在 S3 等待）
// PEA_B_ready : B_FIFO 未滿，所有 16 個 row AND 邏輯輸出
//--------------------------------------------------------------------------
output logic [1:0] global_mode,
output logic global_flush,
output logic [`PE_ARRAY_H*`PE_ARRAY_W-1:0] PE_en,
output logic [10:0] PE_config,
input logic PEA_A_ready,
input logic PEA_B_ready,

//--------------------------------------------------------------------------
// Scan Chain Interface — 全部 tied off，保留給後續整合
//--------------------------------------------------------------------------
output logic set_XID,
output logic set_YID,
output logic set_LN,
output logic [`XID_BITS-1:0] ifmap_XID_scan_in,
output logic [`XID_BITS-1:0] filter_XID_scan_in,
output logic [`XID_BITS-1:0] ipsum_XID_scan_in,
output logic [`XID_BITS-1:0] opsum_XID_scan_in,
output logic [`YID_BITS-1:0] ifmap_YID_scan_in,
output logic [`YID_BITS-1:0] filter_YID_scan_in,
output logic [`YID_BITS-1:0] ipsum_YID_scan_in,
output logic [`YID_BITS-1:0] opsum_YID_scan_in,
output logic [`PE_ARRAY_H-2:0] LN_config_in,

//--------------------------------------------------------------------------
// PPU & GON Interface
//
// PEA_opsum_valid : 由 PE Row → PPU 直接路由，Controller 只管 ready 窗口
// PEA_opsum_ready : 在 S8_WAIT_PPU 期間拉高，授權 PPU 接收資料
// ppu_done : PPU 處理完一個 tile，1-cycle pulse
//--------------------------------------------------------------------------
input logic PEA_opsum_valid,
output logic PEA_opsum_ready,
output logic [`XID_BITS-1:0] opsum_tag_X,
output logic [`YID_BITS-1:0] opsum_tag_Y,
output logic relu_sel,
output logic Maxpool_en,
output logic Maxpool_init,
input logic ppu_done
);

// =========================================================================
// FSM 狀態編碼 (13 states, 4-bit)
// 正確的 M tile 迴圈順序：
// S8_WAIT_PPU → S10_DMA_WRITEBACK → S9b_UPDATE_M → S2/S11
// 先寫回 DRAM（用當前 addr_acc_C），再更新位址（避免 off-by-one）
// =========================================================================
typedef enum logic [3:0] {
S0_IDLE = 4'd0,
S1_SHADOW_LATCH = 4'd1,
S2_DMA_FETCH_A = 4'd2, // 載入 A tile（M tile 邊界才執行）
S3_DMA_FETCH_B = 4'd3, // 載入 B tile（每個 N tile 都執行）
S4_SEND_PE_CONFIG = 4'd4, // 廣播 PE 配置（1 cycle）
S5_MC_DISPATCH = 4'd5, // 送出 mc_start pulse（1 cycle）
S6_WAIT_K_DONE = 4'd6, // 等待 MC 完成 fiber 派發
S7_FLUSH = 4'd7, // 送出 global_flush pulse（1 cycle）
S8_WAIT_PPU = 4'd8, // 等待 PPU 處理完成
S9_UPDATE_NK = 4'd9, // 更新 n_cnt / k_cnt，判斷下一步
S10_DMA_WRITEBACK = 4'd10, // 將 C tile 寫回 DRAM（先寫回）
S9b_UPDATE_M = 4'd11, // 更新 m_cnt / addr_acc（寫回後才更新）
S11_DONE = 4'd12
} state_t;

state_t cs, ns;

// =========================================================================
// Shadow Registers（S1_SHADOW_LATCH 時從 MMIO 鎖入）
// =========================================================================
logic [31:0] comp_A_len;
logic [31:0] comp_B_len;
logic [31:0] comp_C_len; // v7 新增
logic [`N_CNT_BITS-1:0] N_tiles;
logic [`K_CNT_BITS-1:0] K_tiles;
logic [`M_CNT_BITS-1:0] M_tiles;
logic [`PKT_CNT_BITS-1:0] packet_count;
logic [1:0] operation_mode;
logic [`GLB_ADDR_BITS-1:0] GLB_A_base;
logic [`GLB_ADDR_BITS-1:0] GLB_B_base;
logic [`GLB_ADDR_BITS-1:0] GLB_C_base;

// =========================================================================
// MKN Tile Counters
// n_cnt : 0 ~ N_tiles-1
// k_cnt : 0 ~ K_tiles-1
// m_cnt : 0 ~ M_tiles-1
// =========================================================================
logic [`N_CNT_BITS-1:0] n_cnt;
logic [`K_CNT_BITS-1:0] k_cnt;
logic [`M_CNT_BITS-1:0] m_cnt;

// =========================================================================
// Address Accumulators（32-bit，wrap at 4GB）
// addr_acc_A : 每個 M tile 更新一次（在 S9b_UPDATE_M）
// addr_acc_B : 每個 N tile 更新一次（在 S9_UPDATE_NK）
// 每個 M tile 開始時重置為 0
// addr_acc_C : 每個 M tile 更新一次（在 S9b_UPDATE_M，寫回之後）
// =========================================================================
logic [31:0] addr_acc_A;
logic [31:0] addr_acc_B;
logic [31:0] addr_acc_C;

// =========================================================================
// DMA Done Latch Flags（v6 deadlock fix，v7 時機微調）
//
// 問題：DMA_done 是 1-cycle pulse。
// S3 需要 DMA_done_B AND PEA_ready，但兩者未必同 cycle 到達。
// S10 需要 DMA_done_WB，同樣是 pulse。
//
// 解法：sticky flag，set on DMA_done，clear on 離開對應狀態的 cycle。
// FSM 的跳轉條件改用 flag，不再依賴 raw pulse。
//
// dma_a_done_flag : S2_DMA_FETCH_A 期間鎖存，S3 進入時清除
// dma_b_done_flag : S3_DMA_FETCH_B 期間鎖存，S4 進入時清除
// dma_wb_done_flag : S10_DMA_WRITEBACK 期間鎖存，S9b 進入時清除
// =========================================================================
logic dma_a_done_flag;
logic dma_b_done_flag;
logic dma_wb_done_flag;

always_ff @(posedge clk) begin
if (rst || cs == S0_IDLE) begin
dma_a_done_flag <= 1'b0;
dma_b_done_flag <= 1'b0;
dma_wb_done_flag <= 1'b0;
end else begin
// A fetch flag
if (cs == S2_DMA_FETCH_A && DMA_done)
dma_a_done_flag <= 1'b1;
else if (ns == S3_DMA_FETCH_B)
dma_a_done_flag <= 1'b0;

// B fetch flag
if (cs == S3_DMA_FETCH_B && DMA_done)
dma_b_done_flag <= 1'b1;
else if (ns == S4_SEND_PE_CONFIG)
dma_b_done_flag <= 1'b0;

// Writeback flag
if (cs == S10_DMA_WRITEBACK && DMA_done)
dma_wb_done_flag <= 1'b1;
else if (ns == S9b_UPDATE_M)
dma_wb_done_flag <= 1'b0;
end
end

// =========================================================================
// asic_en 兩級同步器（AXI-Lite 跨 clock domain 防 metastability）
// =========================================================================
(* async_reg = "TRUE" *) logic asic_en_sync1;
(* async_reg = "TRUE" *) logic asic_en_sync;

always_ff @(posedge clk) begin
if (rst) begin
asic_en_sync1 <= 1'b0;
asic_en_sync <= 1'b0;
end else begin
asic_en_sync1 <= asic_en;
asic_en_sync <= asic_en_sync1;
end
end

// =========================================================================
// FSM — 狀態暫存器
// =========================================================================
always_ff @(posedge clk) begin
if (rst) cs <= S0_IDLE;
else cs <= ns;
end

// =========================================================================
// FSM — 次態邏輯（純組合）
// =========================================================================
always_comb begin
ns = cs;
case (cs)

S0_IDLE:
if (asic_en_sync) ns = S1_SHADOW_LATCH;

S1_SHADOW_LATCH:
// 1 cycle latch，立刻進 A fetch
ns = S2_DMA_FETCH_A;

S2_DMA_FETCH_A:
// 用 flag，不用 raw pulse
if (dma_a_done_flag) ns = S3_DMA_FETCH_B;

S3_DMA_FETCH_B:
// v7：dma_b_done_flag 和 PEA_ready 獨立等待
// flag 鎖存 DMA_done pulse，不依賴同 cycle 同時到達
if (dma_b_done_flag && PEA_A_ready && PEA_B_ready)
ns = S4_SEND_PE_CONFIG;

S4_SEND_PE_CONFIG:
// 1 cycle PE config 廣播，mc_* 訊號在此 cycle 已穩定
ns = S5_MC_DISPATCH;

S5_MC_DISPATCH:
// mc_start combinational pulse（此 cycle 高電位）
// MC 在此 cycle 的上升沿鎖存所有 mc_* 訊號
ns = S6_WAIT_K_DONE;

S6_WAIT_K_DONE:
if (k_done) ns = S7_FLUSH;

S7_FLUSH:
// global_flush combinational pulse
ns = S8_WAIT_PPU;

S8_WAIT_PPU:
// v7 修正：ppu_done 後先進 S9_UPDATE_NK，判斷是否需要寫回
if (ppu_done) ns = S9_UPDATE_NK;

S9_UPDATE_NK: begin
// 判斷 K×N 是否還有剩餘 tile
// 注意：ns 讀到的 n_cnt/k_cnt 是舊值（always_ff 尚未更新）
if (n_cnt < N_tiles - 1) begin
// 還有 N tile：重載 B，A 重用
ns = S3_DMA_FETCH_B;
end else if (k_cnt < K_tiles - 1) begin
// N 耗盡，還有 K tile：n 重置，k 遞增，重載 B
ns = S3_DMA_FETCH_B;
end else begin
// K×N 全部完成：寫回 C tile
// v7 修正：先寫回，再更新位址
ns = S10_DMA_WRITEBACK;
end
end

S10_DMA_WRITEBACK:
// 用 flag，不用 raw pulse
if (dma_wb_done_flag) ns = S9b_UPDATE_M;

S9b_UPDATE_M:
// 寫回完成後才更新 addr_acc_C 和 m_cnt
if (m_cnt < M_tiles - 1)
ns = S2_DMA_FETCH_A;
else
ns = S11_DONE;

S11_DONE:
// 保持到 host 降下 asic_en
if (!asic_en_sync) ns = S0_IDLE;

default: ns = S0_IDLE;

endcase
end

// =========================================================================
// Datapath — Shadow Latch + Counter Updates + Address Accumulators
// =========================================================================
always_ff @(posedge clk) begin
if (rst || cs == S0_IDLE) begin
comp_A_len <= 32'd0;
comp_B_len <= 32'd0;
comp_C_len <= 32'd0;
N_tiles <= {`N_CNT_BITS{1'b0}};
K_tiles <= {`K_CNT_BITS{1'b0}};
M_tiles <= {`M_CNT_BITS{1'b0}};
packet_count <= {`PKT_CNT_BITS{1'b0}};
operation_mode <= 2'd0;
GLB_A_base <= {`GLB_ADDR_BITS{1'b0}};
GLB_B_base <= {`GLB_ADDR_BITS{1'b0}};
GLB_C_base <= {`GLB_ADDR_BITS{1'b0}};
n_cnt <= {`N_CNT_BITS{1'b0}};
k_cnt <= {`K_CNT_BITS{1'b0}};
m_cnt <= {`M_CNT_BITS{1'b0}};
addr_acc_A <= 32'd0;
addr_acc_B <= 32'd0;
addr_acc_C <= 32'd0;
end
else begin

//------------------------------------------------------------------
// S1：鎖定所有 MMIO 參數到 shadow register
// clamp 所有 tile count 為 ≥1，防止後續比較 underflow
//------------------------------------------------------------------
if (cs == S1_SHADOW_LATCH) begin
comp_A_len <= comp_A_len_in;
comp_B_len <= comp_B_len_in;
comp_C_len <= comp_C_len_in;
N_tiles <= (N_tiles_in >= 1)
? N_tiles_in
: {{(`N_CNT_BITS-1){1'b0}}, 1'b1};
K_tiles <= (K_tiles_in >= 1)
? K_tiles_in
: {{(`K_CNT_BITS-1){1'b0}}, 1'b1};
M_tiles <= (M_tiles_in >= 1)
? M_tiles_in
: {{(`M_CNT_BITS-1){1'b0}}, 1'b1};
packet_count <= (packet_count_in >= 1)
? packet_count_in
: {{(`PKT_CNT_BITS-1){1'b0}}, 1'b1};
operation_mode <= operation_mode_in;
GLB_A_base <= GLB_A_base_addr;
GLB_B_base <= GLB_B_base_addr;
GLB_C_base <= GLB_C_base_addr;
end

//------------------------------------------------------------------
// S9_UPDATE_NK：更新 n_cnt / k_cnt，addr_acc_B
// addr_acc_B 每個 N tile 都遞增（B 不重用）
// n 耗盡時重置，k 遞增；k 耗盡時重置（S9b 會 reset addr_acc_B）
//------------------------------------------------------------------
else if (cs == S9_UPDATE_NK) begin
addr_acc_B <= addr_acc_B + comp_B_len;

if (n_cnt < N_tiles - 1) begin
n_cnt <= n_cnt + 1;
end else begin
n_cnt <= {`N_CNT_BITS{1'b0}};
if (k_cnt < K_tiles - 1) begin
k_cnt <= k_cnt + 1;
end else begin
k_cnt <= {`K_CNT_BITS{1'b0}};
// addr_acc_B 在 S9b 重置
end
end
end

//------------------------------------------------------------------
// S9b_UPDATE_M：寫回 DRAM 完成後才更新位址與 m_cnt
// v7 修正：addr_acc_C 在寫回之後才加，第 0 個 tile 寫到 offset 0
// addr_acc_B 重置為 0（下個 M tile 的 K×N 迴圈重新開始）
//------------------------------------------------------------------
else if (cs == S9b_UPDATE_M) begin
addr_acc_A <= addr_acc_A + comp_A_len;
addr_acc_C <= addr_acc_C + comp_C_len;
addr_acc_B <= 32'd0;
m_cnt <= m_cnt + 1;
// n_cnt, k_cnt 已在 S9_UPDATE_NK 重置為 0
end

end
end

// =========================================================================
// Output Assignments
// =========================================================================

//--------------------------------------------------------------------------
// S11: asic_done（level，持續到 asic_en 降下）
//--------------------------------------------------------------------------
assign asic_done = (cs == S11_DONE);

//--------------------------------------------------------------------------
// DMA Interface
// DMA_en：僅在主動傳輸狀態拉高，等待狀態（S3 等 PEA_ready 時）不拉高
// 這樣 DMA 模組不會誤判為持續傳輸請求
//--------------------------------------------------------------------------
assign DMA_en =
(cs == S2_DMA_FETCH_A && !dma_a_done_flag) ||
(cs == S3_DMA_FETCH_B && !dma_b_done_flag) ||
(cs == S10_DMA_WRITEBACK && !dma_wb_done_flag);

assign DMA_mode =
(cs == S2_DMA_FETCH_A) ? 2'd0 : // IFMAP / A fiber
(cs == S3_DMA_FETCH_B) ? 2'd1 : // FILTER / B fiber
(cs == S10_DMA_WRITEBACK) ? 2'd3 : // OFMAP / C tensor
2'd0;

assign DMA_DRAM_ADDR =
(cs == S2_DMA_FETCH_A) ? (A_fiber_base_addr + addr_acc_A) :
(cs == S3_DMA_FETCH_B) ? (B_fiber_base_addr + addr_acc_B) :
(cs == S10_DMA_WRITEBACK) ? (C_tensor_base_addr + addr_acc_C) :
{`AXI_ADDR_BITS{1'b0}};

assign DMA_GLB_ADDR =
(cs == S2_DMA_FETCH_A) ? GLB_A_base :
(cs == S3_DMA_FETCH_B) ? GLB_B_base :
(cs == S10_DMA_WRITEBACK) ? GLB_C_base :
{`GLB_ADDR_BITS{1'b0}};

assign DMA_len =
(cs == S2_DMA_FETCH_A) ? comp_A_len :
(cs == S3_DMA_FETCH_B) ? comp_B_len :
(cs == S10_DMA_WRITEBACK) ? comp_C_len : // v7：用 shadow register
32'd0;

//--------------------------------------------------------------------------
// MC Interface
// mc_* 訊號從 S4 開始就穩定，MC 可提前讀取
// mc_start 只在 S5_MC_DISPATCH 這一個 cycle 拉高
//--------------------------------------------------------------------------
assign mc_start = (cs == S5_MC_DISPATCH);
assign mc_mode = operation_mode;
assign mc_glb_base_A = GLB_A_base;
assign mc_glb_base_B = GLB_B_base;
assign mc_packet_count = packet_count;

//--------------------------------------------------------------------------
// PE Array Interface
//--------------------------------------------------------------------------
assign global_mode = operation_mode;
assign global_flush = (cs == S7_FLUSH);

// PE_en：S4~S8 期間全部拉高（用明確狀態列舉，不用 range 比較）
assign PE_en =
(cs == S4_SEND_PE_CONFIG ||
cs == S5_MC_DISPATCH ||
cs == S6_WAIT_K_DONE ||
cs == S7_FLUSH ||
cs == S8_WAIT_PPU)
? {(`PE_ARRAY_H * `PE_ARRAY_W){1'b1}}
: {(`PE_ARRAY_H * `PE_ARRAY_W){1'b0}};

// PE_config bit layout: [10:9]=mode [8:5]=e [4:2]=p [1:0]=q[1:0]
assign PE_config = {operation_mode, e, p, q[1:0]};

//--------------------------------------------------------------------------
// PPU Interface
//--------------------------------------------------------------------------
assign PEA_opsum_ready = (cs == S8_WAIT_PPU);
assign opsum_tag_X = {`XID_BITS{1'b0}}; // TODO: 接入 tiling 位址計算
assign opsum_tag_Y = {`YID_BITS{1'b0}}; // TODO: 接入 tiling 位址計算
assign relu_sel = operation_mode[0]; // TrIP[0]=1 → ReLU 啟用
assign Maxpool_en = 1'b0; // TODO: 接入 CSR
assign Maxpool_init = 1'b0; // TODO: 接入 CSR

//--------------------------------------------------------------------------
// Scan Chain — Tied Off
//--------------------------------------------------------------------------
assign set_XID = 1'b0;
assign set_YID = 1'b0;
assign set_LN = 1'b0;
assign ifmap_XID_scan_in = {`XID_BITS{1'b0}};
assign filter_XID_scan_in = {`XID_BITS{1'b0}};
assign ipsum_XID_scan_in = {`XID_BITS{1'b0}};
assign opsum_XID_scan_in = {`XID_BITS{1'b0}};
assign ifmap_YID_scan_in = {`YID_BITS{1'b0}};
assign filter_YID_scan_in = {`YID_BITS{1'b0}};
assign ipsum_YID_scan_in = {`YID_BITS{1'b0}};
assign opsum_YID_scan_in = {`YID_BITS{1'b0}};
assign LN_config_in = {(`PE_ARRAY_H-1){1'b0}};

//--------------------------------------------------------------------------
// Unused Input Suppression（防止 lint 警告）
//--------------------------------------------------------------------------
logic unused_ok;
assign unused_ok = ^{r, t, PEA_opsum_valid};

// =========================================================================
// Simulation-Only Assertions
// =========================================================================
`ifdef SIMULATION

//--------------------------------------------------------------------------
// S1：MMIO 參數合法性檢查
//--------------------------------------------------------------------------
always_ff @(posedge clk) begin
if (cs == S1_SHADOW_LATCH) begin

assert (N_tiles_in >= 1)
else $error("[CTRL %0t] N_tiles_in=%0d < 1，將 clamp 為 1",
$time, N_tiles_in);
assert (K_tiles_in >= 1)
else $error("[CTRL %0t] K_tiles_in=%0d < 1，將 clamp 為 1",
$time, K_tiles_in);
assert (M_tiles_in >= 1)
else $error("[CTRL %0t] M_tiles_in=%0d < 1，將 clamp 為 1",
$time, M_tiles_in);
assert (packet_count_in >= 1)
else $error("[CTRL %0t] packet_count_in=0，將 clamp 為 1", $time);

// comp_A/B/C_len 必須非零且 4B 對齊（AXI 32b 寬度）
assert (comp_A_len_in > 0 && comp_A_len_in[1:0] == 2'b00)
else $error("[CTRL %0t] comp_A_len_in=0x%08X：零或非 4B 對齊",
$time, comp_A_len_in);
assert (comp_B_len_in > 0 && comp_B_len_in[1:0] == 2'b00)
else $error("[CTRL %0t] comp_B_len_in=0x%08X：零或非 4B 對齊",
$time, comp_B_len_in);
assert (comp_C_len_in > 0 && comp_C_len_in[1:0] == 2'b00)
else $error("[CTRL %0t] comp_C_len_in=0x%08X：零或非 4B 對齊",
$time, comp_C_len_in);

// operation_mode 只允許 STD_IP 或 TRIP
assert (operation_mode_in == `MODE_STD_IP ||
operation_mode_in == `MODE_TRIP)
else $error("[CTRL %0t] operation_mode_in=2'b%02b 是保留值",
$time, operation_mode_in);
end
end

//--------------------------------------------------------------------------
// S4：q[2] 必須為 0（PE_config 只用 q[1:0]）
//--------------------------------------------------------------------------
always_ff @(posedge clk) begin
if (cs == S4_SEND_PE_CONFIG)
assert (q[2] == 1'b0)
else $error("[CTRL %0t] q[2]=1 被靜默丟棄，mapping 有誤", $time);
end

//--------------------------------------------------------------------------
// S3：PEA_ready watchdog（dma_b_done_flag 置位後 200 cycle 限制）
//--------------------------------------------------------------------------
logic [15:0] pea_watchdog;
always_ff @(posedge clk) begin
if (rst || cs != S3_DMA_FETCH_B || !dma_b_done_flag)
pea_watchdog <= 16'd0;
else if (!(PEA_A_ready && PEA_B_ready)) begin
pea_watchdog <= pea_watchdog + 16'd1;
assert (pea_watchdog < 16'd200)
else $error("[CTRL %0t] S3 PEA_ready timeout：DMA 完成後 %0d cycles 仍未 ready",
$time, pea_watchdog);
end
end

//--------------------------------------------------------------------------
// S2 入口：addr_acc_B 必須為 0（每個 M tile 開始前 B 位址必須重置）
//--------------------------------------------------------------------------
always_ff @(posedge clk) begin
if (cs == S2_DMA_FETCH_A)
assert (addr_acc_B == 32'd0)
else $error("[CTRL %0t] addr_acc_B=0x%08X 進入 S2，B 位址重置遺漏",
$time, addr_acc_B);
end

//--------------------------------------------------------------------------
// 進入 S3 時：dma_b_done_flag 必須為 0（應已被清除）
//--------------------------------------------------------------------------
always_ff @(posedge clk) begin
if (cs == S2_DMA_FETCH_A && ns == S3_DMA_FETCH_B)
assert (dma_b_done_flag == 1'b0)
else $error("[CTRL %0t] dma_b_done_flag 進入 S3 時未清除", $time);
end

//--------------------------------------------------------------------------
// mc_start 必須只有一個 cycle 高電位
//--------------------------------------------------------------------------
logic mc_start_prev;
always_ff @(posedge clk) mc_start_prev <= mc_start;
always_ff @(posedge clk) begin
if (mc_start_prev && mc_start)
$error("[CTRL %0t] mc_start 連續兩個 cycle 高電位，違反 pulse 規範", $time);
end

//--------------------------------------------------------------------------
// global_flush 必須只有一個 cycle 高電位
//--------------------------------------------------------------------------
logic flush_prev;
always_ff @(posedge clk) flush_prev <= global_flush;
always_ff @(posedge clk) begin
if (flush_prev && global_flush)
$error("[CTRL %0t] global_flush 連續兩個 cycle 高電位，違反 pulse 規範", $time);
end

`endif // SIMULATION

endmodule