#pragma once
#include <stdint.h>

// =============================================================================
// case_SRAM/data.h — Test vectors for SRAM_rtl unit test
//
// Test coverage:
// TC01 Normal write + read
// TC02 BWEB partial mask (write only low 32-bit)
// TC03 All-zeros and all-ones patterns
// TC04 Alternating bit patterns (walking 1/0)
// TC05 Address boundary (addr 0 and addr 127)
// =============================================================================

// Number of entries in each test vector array
#define SRAM_TC01_WORDS 8
#define SRAM_TC03_WORDS 2
#define SRAM_TC04_WORDS 4
#define SRAM_TC05_WORDS 2

// TC01 — Normal write/read: 8 distinct 64-bit values
static const uint64_t tc01_data[SRAM_TC01_WORDS] = {
0x00000000DEADBEEFULL,
0x00000000CAFEBABEULL,
0x12345678DEADBEEFULL,
0xABCDEF0123456789ULL,
0x00FF00FFFF00FF00ULL,
0xFF00FF0000FF00FFULL,
0xA5A5A5A55A5A5A5AULL,
0x5A5A5A5AA5A5A5A5ULL,
};

// TC02 — BWEB partial mask test
// Write full_val first, then overwrite with partial_val using mask.
// Only low 32-bit should change; high 32-bit must retain full_val.
#define SRAM_TC02_ADDR 10
static const uint64_t tc02_full_val = 0xFFFFFFFFFFFFFFFFULL;
static const uint64_t tc02_partial_val = 0x00000000DEADBEEFULL;
// BWEB=0 means "write this bit"; mask only low 32 bits
static const uint64_t tc02_mask = 0xFFFFFFFF00000000ULL; // keep high 32, write low 32
// Expected after partial write:
// high 32 = 0xFFFFFFFF (from full_val, protected by mask)
// low 32 = 0xDEADBEEF (from partial_val)
static const uint64_t tc02_expected = 0xFFFFFFFFDEADBEEFULL;

// TC03 — All-zeros and all-ones
#define SRAM_TC03_BASE_ADDR 20
static const uint64_t tc03_data[SRAM_TC03_WORDS] = {
0x0000000000000000ULL,
0xFFFFFFFFFFFFFFFFULL,
};

// TC04 — Alternating patterns (walking bit)
#define SRAM_TC04_BASE_ADDR 30
static const uint64_t tc04_data[SRAM_TC04_WORDS] = {
0xAAAAAAAAAAAAAAAAULL,
0x5555555555555555ULL,
0x5A5A5A5A5A5A5A5AULL,
0xA5A5A5A5A5A5A5A5ULL,
};

// TC05 — Address boundary: addr 0 and addr 127 (max for 7-bit)
#define SRAM_TC05_ADDR_LO 0
#define SRAM_TC05_ADDR_HI 127
static const uint64_t tc05_data[SRAM_TC05_WORDS] = {
0x0123456789ABCDEFULL,
0xFEDCBA9876543210ULL,
};
