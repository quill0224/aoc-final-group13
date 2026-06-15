#pragma once
#include <cstdint>

// Integration test: Controller + DMA + GLB end-to-end
// 1 tile, TrIP mode, 1 fiber packet
// Flow: CPU sets MMIO → asic_en → DMA fetches A/B → MC dispatches →
//       PE computes (stubbed) → PPU writes (stubbed) → DMA writes back C

// One fiber packet = 20 bytes = 5 × 32-bit words
// Packet format: [word0] = {mode[1:0], bitmask[15:0], NZ[127:112]}
//                [word1..4] = NZ[111:0] + padding

static const int  INT_PKT_WORDS    = 5;
static const int  INT_C_WORDS      = 4;  // output tile 16 bytes

// DRAM A source (1 packet = 20 bytes)
static const uint32_t INT_DRAM_A_BASE = 0x00010000;
static const uint32_t int_dram_a[5] = {
    0x01FF0001,   // mode=01, bitmask=0xFF00, NZ[127:112]=0x0001
    0x02030405,
    0x06070809,
    0x0A0B0C0D,
    0x0E0F0000    // last 2 bytes padding
};

// DRAM B source (1 packet = 20 bytes)
static const uint32_t INT_DRAM_B_BASE = 0x00020000;
static const uint32_t int_dram_b[5] = {
    0x01AABB01,
    0xCCDDEEFF,
    0x11223344,
    0x55667788,
    0x99AA0000
};

// Expected GLB_C content after PPU (stub: just copies zeros for now)
// Real PPU output would be INT8 quantized; here we preload and verify DMA WB
static const uint32_t INT_DRAM_C_BASE  = 0x00030000;
static const uint32_t INT_GLB_A_BASE   = 0x0000;
static const uint32_t INT_GLB_B_BASE   = 0x0140;
static const uint32_t INT_GLB_C_BASE   = 0x0280;

// Simulated PPU output placed in GLB_C before writeback verification
static const uint32_t int_ppu_output[4] = {
    0x7F807F80,
    0x7F807F80,
    0x7F807F80,
    0x7F807F80
};

// Tile parameters
static const uint32_t INT_COMP_A_LEN = 20;
static const uint32_t INT_COMP_B_LEN = 20;
static const uint32_t INT_COMP_C_LEN = 16;
static const uint8_t  INT_N_TILES    = 1;
static const uint16_t INT_K_TILES    = 1;
static const uint8_t  INT_M_TILES    = 1;
static const uint8_t  INT_PKT_COUNT  = 1;
static const uint8_t  INT_OP_MODE    = 0x01; // TrIP