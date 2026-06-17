#pragma once
#include <stdint.h>

// =============================================================================
// case_INTEGRATION/data.h — System Address Map & Tiling Configuration
// =============================================================================

// -----------------------------------------------------------------------------
// DRAM 實體地址規劃 (防止 Width Truncation 導致地址重疊碰撞)
// -----------------------------------------------------------------------------
#define INT_A_DRAM_BASE        0x00000000U  
#define INT_B_DRAM_BASE        0x00010000U  
#define INT_C_DRAM_BASE        0x00020000U  

// -----------------------------------------------------------------------------
// GLB 內部靜態地址規劃
// -----------------------------------------------------------------------------
#define INT_GLB_A_BASE         0x0000U      
#define INT_GLB_B_BASE         0x1000U      
#define INT_GLB_C_BASE         0x2000U      

// -----------------------------------------------------------------------------
// 神經網路硬體執行參數
// -----------------------------------------------------------------------------
#define INT_A_LEN              64U          
#define INT_B_LEN              64U          
#define INT_C_LEN              64U          

#define INT_M_TILES            1U           
#define INT_K_TILES            1U           
#define INT_N_TILES            2U           

#define INT_PACKET_COUNT       16U          
#define INT_OP_MODE            0U           
