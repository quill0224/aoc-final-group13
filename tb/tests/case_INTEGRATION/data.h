// #pragma once
// #include <stdint.h>

// // =============================================================================
// // case_INTEGRATION/data.h — Layer 40 Conv (features.40) 系統參數
// //
// // Layer 規格（來自 layer_meta.txt）：
// //   GEMM M = 196  (14×14 output spatial)
// //   GEMM K = 4608 (512 input ch × 3×3 filter)
// //   GEMM N = 512  (output channels)
// //
// // Tiling（tile_size = 16）：
// //   M_tiles = ceil(196/16) = 13  （最後一個 tile 不足 16，padding 處理）
// //   K_tiles = ceil(4608/16) = 288
// //   N_tiles = ceil(512/16)  = 32
// //   packet_count per tile = 16  （1 tile = 16 fibers = 16 packets）
// // =============================================================================

// // --- GEMM 維度 ---------------------------------------------------------------
// #define GEMM_M          196
// #define GEMM_K          4608
// #define GEMM_N          512
// #define TILE_SIZE       16

// // --- Tile 計數 ---------------------------------------------------------------
// #define M_TILES         13      // ceil(196/16)
// #define K_TILES         288     // 4608/16
// #define N_TILES         32      // 512/16
// #define PKTS_PER_TILE   16      // 每個 tile 的 packet 數（= tile_size）

// // --- DRAM 地址規劃 -----------------------------------------------------------
// // A tile 最大 bytes = 16 pkts × 20 bytes = 320 bytes
// // B tile 最大 bytes = 320 bytes
// // 給 A 留 64KB，給 B 留 64KB，C 輸出從 128KB 開始
// #define DRAM_A_BASE     0x00000000U   // A fiber data in DRAM
// #define DRAM_B_BASE     0x00010000U   // B fiber data in DRAM (reserved)
// #define DRAM_C_BASE     0x00020000U   // C output write-back target

// // --- GLB 地址規劃（來自 ASIC.svh）--------------------------------------------
// #define GLB_A_BASE      0x0000U       // 0x0000~0x013F (320 bytes)
// #define GLB_B_BASE      0x0140U       // 0x0140~0x027F (320 bytes)
// #define GLB_C_BASE      0x0280U       // 0x0280~0x037F (256 bytes)

// // --- 每個 tile 的 A 壓縮資料長度 ---------------------------------------------
// // 固定 = PKTS_PER_TILE × 20 = 320 bytes（worst case，實際稀疏資料也是 320 因為 MC 固定讀 5 words）
// #define A_TILE_BYTES    320U          // 16 pkts × 20 bytes
// #define B_TILE_BYTES    320U
// #define C_TILE_BYTES    256U          // 16×16 INT8 output

// // --- 量化參數（來自 quant_meta.txt）------------------------------------------
// #define REQUANT_SHIFT   9

// // --- 操作模式 ----------------------------------------------------------------
// #define OP_MODE_TRIP    0x01U         // TrIP sparse dataflow

// // --- 32-bit ASIC 啟動指令格式 ------------------------------------------------
// // [31]    start       1-bit   寫 1 啟動
// // [30:29] mode        2-bit   00=IP, 01=TrIP
// // [28:22] M_tiles     7-bit   max 49 → 7-bit
// // [21:12] K_tiles    10-bit   max 288 → 10-bit
// // [11:6]  N_tiles     6-bit   max 32 → 6-bit
// // [5:1]   pkt_count   5-bit   max 16 → 5-bit
// // [0]     reserved    1-bit
// //
// // 範例：Layer 40 full run (TrIP, M=13, K=288, N=32, pkt=16)
// //   start=1, mode=01, M=13(0x0D), K=288(0x120), N=32(0x20), pkt=16(0x10)
// //   = 1_01_0001101_1001000000_100000_10000_0
// //   = 0xA1_B2_08_20  （計算如下）
// //
// // 計算：
// //   [31]    = 1        → 0x80000000
// //   [30:29] = 01       → 0x20000000
// //   [28:22] = 0001101  → 0x01A00000  (13 << 22)
// //   [21:12] = 1001000000 → 0x00120000... 需要重算
// //
// // 正確計算：
// //   start  (bit 31)     = 1             = 0x80000000
// //   mode   (bits 30:29) = 1 (TrIP)     = 0x20000000
// //   M      (bits 28:22) = 13            = 13 << 22 = 0x03400000
// //   K      (bits 21:12) = 288           = 288 << 12 = 0x00120000
// //   N      (bits 11:6)  = 32            = 32 << 6 = 0x00000800
// //   pkt    (bits 5:1)   = 16            = 16 << 1 = 0x00000020
// //   OR all = 0x80000000|0x20000000|0x03400000|0x00120000|0x00000800|0x00000020
// //          = 0xA3520820
// #define ASIC_CMD_LAYER40  0xA3520820U

// // --- 輔助 macro：從 32-bit 指令解碼各欄位 ------------------------------------
// #define CMD_START(cmd)  (((cmd) >> 31) & 0x1)
// #define CMD_MODE(cmd)   (((cmd) >> 29) & 0x3)
// #define CMD_M(cmd)      (((cmd) >> 22) & 0x7F)
// #define CMD_K(cmd)      (((cmd) >> 12) & 0x3FF)
// #define CMD_N(cmd)      (((cmd) >>  6) & 0x3F)
// #define CMD_PKT(cmd)    (((cmd) >>  1) & 0x1F)

// // --- 小 tile demo 指令（用於快速驗證，M=1 K=1 N=2）--------------------------
// // start=1, mode=01, M=1, K=1, N=2, pkt=16
// //   0x80000000 | 0x20000000 | (1<<22) | (1<<12) | (2<<6) | (16<<1)
// //   = 0xA0400480 | 0x1000 | 0x80 | 0x20
// //   = 0xA0401120... 重算
// // 用你自己的 macro 比較方便，這裡提供 debug 用小 tile 值
// #define ASIC_CMD_SMALL  0xA0010041U   // M=1,K=1,N=1,pkt=16 (你原本 demo 的值)

// // --- 測試等級選擇 ------------------------------------------------------------
// // 在 workload.c 中 define 以下其中一個：
// // #define TEST_SMALL_TILE    // 只跑 M=1,K=1,N=1，快速驗證 MC 解析
// // #define TEST_FULL_LAYER    // 跑完整 M=13,K=288,N=32

// // --- hex 檔路徑（相對於 tb/testbench/dla）------------------------------------
// #define DRAM_HEX_PATH         "dram_test.hex"
// #define MASK_PATH_A   "../../../GEMM/outputs/layer_40_conv/hw_bitmask/input_A_bitmask_64b_hex.txt"
// #define VAL_PATH_A    "../../../GEMM/outputs/layer_40_conv/hw_bitmask/input_A_values_hex.txt"
// #define GOLDEN_OUT    "../../../GEMM/outputs/layer_40_conv/hw_bitmask/golden_output_values_hex.txt"

// =============================================================================
// 核心設定：32-bit ASIC 啟動指令 (ASIC Command)
// =============================================================================
// 指令結構 (32-bit):
// [31]      Start 啟動訊號 (1 bit)  : 1 代表啟動
// [30:29]   Mode  操作模式 (2 bits) : 00=Dense, 01=Sparse(TrIP), 10/11=保留
// [28:22]   M     M-Tiles (7 bits)  : 最大 127
// [21:12]   K     K-Tiles (10 bits) : 最大 1023
// [11:6]    N     N-Tiles (6 bits)  : 最大 63
// [5:1]     Pkt   Packet/Tile(5 bits): 固定填 16 (16個封包為一個Tile, 即0x10)
// [0]       Rsv   保留位 (1 bit)    : 填 0
//


#pragma once
#include <stdint.h>

// =============================================================================
// [1] 核心控制暫存器 (ASIC Command Register)
// =============================================================================
// 32-bit 指令欄位定義:
// [31]      Start : 1-bit 啟動訊號
// [30:29]   Mode  : 2-bit 操作模式 (01 = TrIP Sparse Dataflow)
// [28:22]   M     : 7-bit M-Tiles 數量 (Max 127)
// [21:12]   K     : 10-bit K-Tiles 數量 (Max 1023)
// [11:6]    N     : 6-bit N-Tiles 數量 (Max 63)
// [5:1]     Pkt   : 5-bit Packet per Tile (固定 16)
// [0]       Rsv   : 1-bit 保留位
// -----------------------------------------------------------------------------
#define BUILD_ASIC_CMD(start, mode, m, k, n, pkt) \
    ( (((uint32_t)(start) & 0x1) << 31) | \
      (((uint32_t)(mode)  & 0x3) << 29) | \
      (((uint32_t)(m)     & 0x7F) << 22) | \
      (((uint32_t)(k)     & 0x3FF) << 12) | \
      (((uint32_t)(n)     & 0x3F) << 6) | \
      (((uint32_t)(pkt)   & 0x1F) << 1) )

// 封裝固定參數 (Start=1, Mode=1, Pkt=16) 的函數型巨集
#define GEN_ASIC_CMD(m, k, n)   BUILD_ASIC_CMD(1, 1, (m), (k), (n), 16)

// =============================================================================
// [2] 測試規模切換區 (唯一修改點)
// =============================================================================
// 請直接修改此處的 M, K, N 參數。系統將自動推算需要的測資封包量與暫存器設定。
// Layer 40 全層運算設定範例: GEN_ASIC_CMD(13, 288, 32)
#define ACTIVE_ASIC_CMD   GEN_ASIC_CMD(3, 3, 3)

// -----------------------------------------------------------------------------
// [3] 暫存器解碼巨集 (供 Testbench 解析寫入 MMIO)
// -----------------------------------------------------------------------------
#define CMD_START(cmd)  (((cmd) >> 31) & 0x1)
#define CMD_MODE(cmd)   (((cmd) >> 29) & 0x3)
#define CMD_M(cmd)      (((cmd) >> 22) & 0x7F)
#define CMD_K(cmd)      (((cmd) >> 12) & 0x3FF)
#define CMD_N(cmd)      (((cmd) >>  6) & 0x3F)
#define CMD_PKT(cmd)    (((cmd) >>  1) & 0x1F)

// =============================================================================
// [4] 記憶體映射與系統參數 (Memory Map Configuration)
// =============================================================================
#define DRAM_A_BASE     0x00000000U
#define DRAM_B_BASE     0x00010000U
#define DRAM_C_BASE     0x00020000U

#define GLB_A_BASE      0x0000U
#define GLB_B_BASE      0x0140U
#define GLB_C_BASE      0x0280U

#define A_TILE_BYTES    320U
#define B_TILE_BYTES    320U
#define C_TILE_BYTES    256U

// =============================================================================
// [5] 測資路徑定義 (Data Paths)
// =============================================================================
#define DRAM_HEX_PATH "dram_test.hex"
#define MASK_PATH_A   "../../../GEMM/outputs/layer_40_conv/hw_bitmask/input_A_bitmask_64b_hex.txt"
#define VAL_PATH_A    "../../../GEMM/outputs/layer_40_conv/hw_bitmask/input_A_values_hex.txt"
