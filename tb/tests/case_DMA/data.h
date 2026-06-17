#pragma once
#include <stdint.h>

// =============================================================================
// case_DMA/data.h — Test vectors for DMA unit test
//
// DRAM layout (simulated by AXI slave stub in workload.c):
// Address 0x1000_0000 : A tile data (fetch test)
// Address 0x2000_0000 : B tile data (fetch test)
// Address 0x3000_0000 : C tile writeback destination
//
// All lengths must be 4B-aligned (AXI_DATA_BITS=32).
// Each packet is 20 bytes; one tile = 16 packets = 320 bytes.
// =============================================================================

// -------------------------------------------------------
// TC01 — Single fetch A tile (DRAM→GLB), no back-pressure
// -------------------------------------------------------
#define TC01_DRAM_BASE 0x10000000U
#define TC01_GLB_BASE  0x0000U // GLB_A_BASE
#define TC01_LEN       320U    // 16 pkts × 20 bytes
#define TC01_BEATS     80U     // 320 / 4

// DRAM data pattern: word[i] = base_addr + i*4 (lower 32-bit)
// AXI slave generates this on the fly; no static array needed.

// -------------------------------------------------------
// TC02 — Fetch B tile with ARREADY back-pressure (5-cycle delay)
// -------------------------------------------------------
#define TC02_DRAM_BASE 0x20000000U
#define TC02_GLB_BASE  0x0140U // GLB_B_BASE
#define TC02_LEN       320U
#define TC02_BEATS     80U
#define TC02_AR_DELAY  5       // cycles before ARREADY

// -------------------------------------------------------
// TC03 — Fetch requiring chunking (>1024B = 2 bursts)
// -------------------------------------------------------
#define TC03_DRAM_BASE  0x10000000U
#define TC03_GLB_BASE   0x0000U
#define TC03_LEN        1280U  // 1024 + 256 → 2 bursts
#define TC03_BEATS      320U
#define TC03_BURST0_LEN 1024U  // first chunk
#define TC03_BURST1_LEN 256U   // second chunk

// -------------------------------------------------------
// TC04 — Writeback C tile (GLB→DRAM), no back-pressure
// GLB is pre-filled with a known pattern before writeback.
// -------------------------------------------------------
#define TC04_DRAM_BASE 0x30000000U
#define TC04_GLB_BASE  0x0280U // GLB_C_BASE
#define TC04_LEN       256U    // 16×16 × 1 byte
#define TC04_BEATS     64U     // 256 / 4

// GLB data pattern for writeback: word[i] = 0xC0000000 | i
static inline uint32_t tc04_glb_word(uint32_t beat_idx) {
    return 0xC0000000U | beat_idx;
}

// -------------------------------------------------------
// TC05 — Writeback with WREADY stall (every 3rd beat)
// -------------------------------------------------------
#define TC05_DRAM_BASE     0x30000000U
#define TC05_GLB_BASE      0x0280U
#define TC05_LEN           256U
#define TC05_BEATS         64U
#define TC05_WREADY_PERIOD 3 // WREADY=0 for 2 cycles, 1 for 1 cycle