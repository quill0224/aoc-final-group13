#pragma once
#include <stdint.h>

// =============================================================================
// case_CTRL/data.h — Test Vectors for top_controller FSM & Loop Bounds
// =============================================================================

// -----------------------------------------------------------------------------
// TC01: 基礎單一組合 (1x1x1) — 驗證最短路徑與狀態機閉環
// -----------------------------------------------------------------------------
#define TC01_A_DRAM_BASE       0x10000000U
#define TC01_B_DRAM_BASE       0x20000000U
#define TC01_C_DRAM_BASE       0x30000000U
#define TC01_A_GLB_BASE        0x0000U
#define TC01_B_GLB_BASE        0x0140U
#define TC01_C_GLB_BASE        0x0280U
#define TC01_A_LEN             320U
#define TC01_B_LEN             320U
#define TC01_C_LEN             256U
#define TC01_M_TILES           1U
#define TC01_K_TILES           1U
#define TC01_N_TILES           1U

// -----------------------------------------------------------------------------
// TC02: 多 N-tile 巢狀組合 (1x1x3) — 驗證 B 位址連續累積與 N 迴圈計數器跳轉
// -----------------------------------------------------------------------------
#define TC02_A_DRAM_BASE       0x11000000U
#define TC02_B_DRAM_BASE       0x21000000U
#define TC02_C_DRAM_BASE       0x31000000U
#define TC02_A_GLB_BASE        0x0000U
#define TC02_B_GLB_BASE        0x0140U
#define TC02_C_GLB_BASE        0x0280U
#define TC02_A_LEN             64U
#define TC02_B_LEN             128U
#define TC02_C_LEN             256U
#define TC02_M_TILES           1U
#define TC02_K_TILES           1U
#define TC02_N_TILES           3U

// -----------------------------------------------------------------------------
// TC03: 完整 MKN 巢狀迴圈 (2x2x2) — 驗證 A/C 累積、B 位址重置（Rewind）與計數器切換
// -----------------------------------------------------------------------------
#define TC03_A_DRAM_BASE       0x12000000U
#define TC03_B_DRAM_BASE       0x22000000U
#define TC03_C_DRAM_BASE       0x32000000U
#define TC03_A_GLB_BASE        0x0000U
#define TC03_B_GLB_BASE        0x0140U
#define TC03_C_GLB_BASE        0x0280U
#define TC03_A_LEN             1024U
#define TC03_B_LEN             512U
#define TC03_C_LEN             1024U
#define TC03_M_TILES           2U
#define TC03_K_TILES           2U
#define TC03_N_TILES           2U