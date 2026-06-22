#pragma once
#include <stdint.h>

// =============================================================================
// C-Macro implementation of the 32-bit ASIC Command Generator
// =============================================================================
// Command Structure (32-bit):
// [31]      Start (1-bit)
// [30:29]   Mode  (2-bits, 01=TrIP)
// [28:22]   M     (7-bits, Max 127)
// [21:12]   K     (10-bits, Max 1023)
// [11:6]    N     (6-bits, Max 63)
// [5:1]     Pkt   (5-bits, fixed to 16)
// [0]       Rsv   (1-bit)
// -----------------------------------------------------------------------------
#define BUILD_ASIC_CMD(start, mode, m, k, n, pkt) \
    ( (((uint32_t)(start) & 0x1) << 31) | \
      (((uint32_t)(mode)  & 0x3) << 29) | \
      (((uint32_t)(m)     & 0x7F) << 22) | \
      (((uint32_t)(k)     & 0x3FF) << 12) | \
      (((uint32_t)(n)     & 0x3F) << 6) | \
      (((uint32_t)(pkt)   & 0x1F) << 1) )

// 封裝固定參數 (Start=1, Mode=1, Pkt=16)
// 呼叫方式：GEN_ASIC_CMD(M的數量, K的數量, N的數量)
#define GEN_ASIC_CMD(m, k, n)   BUILD_ASIC_CMD(1, 1, (m), (k), (n), 16)

// =============================================================================
// ⭐️ TEST SCALE SELECTOR (直接在這裡修改你的 M, K, N) ⭐️
// =============================================================================
#define ACTIVE_ASIC_CMD   GEN_ASIC_CMD(2, 2, 2)
// =============================================================================

// Decoder Macros for Testbench Tracking
#define CMD_START(cmd)  (((cmd) >> 31) & 0x1)
#define CMD_MODE(cmd)   (((cmd) >> 29) & 0x3)
#define CMD_M(cmd)      (((cmd) >> 22) & 0x7F)
#define CMD_K(cmd)      (((cmd) >> 12) & 0x3FF)
#define CMD_N(cmd)      (((cmd) >>  6) & 0x3F)
#define CMD_PKT(cmd)    (((cmd) >>  1) & 0x1F)

// =============================================================================
// Memory Map Configuration
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
// Data Paths
// =============================================================================
// Two separate HEX files will be generated for A (IFMAP) and B (Filter)
#define DRAM_HEX_PATH_A "dram_test_A.hex"
#define DRAM_HEX_PATH_B "dram_test_B.hex"
#define MASK_PATH_A     "../../../GEMM/outputs/layer_40_conv/hw_bitmask/input_A_bitmask_64b_hex.txt"
#define VAL_PATH_A      "../../../GEMM/outputs/layer_40_conv/hw_bitmask/input_A_values_hex.txt"
#define MASK_PATH_B     "../../../GEMM/outputs/layer_40_conv/hw_bitmask/input_B_bitmask_64b_hex.txt"
#define VAL_PATH_B      "../../../GEMM/outputs/layer_40_conv/hw_bitmask/input_B_values_hex.txt"
