#pragma once
#include <cstdint>

// DMA test case:
// Fetch: load 20 bytes (5 words = 1 fiber packet) from DRAM→GLB_A
// Writeback: read 16 bytes (4 words) from GLB_C→DRAM

// DRAM layout (word addresses)
static const uint32_t DRAM_A_BASE = 0x00010000; // DRAM source for A fetch
static const uint32_t DRAM_C_BASE = 0x00020000; // DRAM dest  for C writeback

// GLB targets (byte addresses, from ASIC.svh)
static const uint16_t GLB_A_BASE  = 0x0000;
static const uint16_t GLB_C_BASE  = 0x0280;

// Source data in DRAM (5 words = 20 bytes = 1 packet)
// Layout: [word0]=mode+bitmask_hi, [word1]=bitmask_lo+NZ[0:1],
//         [word2..4]=NZ values (simplified for test)
static const int DMA_FETCH_WORDS = 5;
static const uint32_t dram_a_src[5] = {
    0x0100FF01,  // mode=01(TrIP), bitmask[15:8]=0xFF, bitmask[7:0]=0x01 (hi word)
    0x010203FF,  // NZ values packing start
    0x04050607,
    0x08090A0B,
    0x0C0D0E0F
};

// Expected GLB_A content after fetch
static const uint32_t glb_a_expected[5] = {
    0x0100FF01, 0x010203FF, 0x04050607, 0x08090A0B, 0x0C0D0E0F
};

// Content to place in GLB_C for writeback test (4 words = 16 bytes)
static const int DMA_WB_WORDS = 4;
static const uint32_t glb_c_src[4] = {
    0xAABBCCDD, 0x11223344, 0x55667788, 0x99AABBCC
};

// Expected DRAM content after writeback
static const uint32_t dram_c_expected[4] = {
    0xAABBCCDD, 0x11223344, 0x55667788, 0x99AABBCC
};

// DMA_len values
static const uint32_t DMA_A_LEN = 20; // 5 words × 4 bytes
static const uint32_t DMA_C_LEN = 16; // 4 words × 4 bytes