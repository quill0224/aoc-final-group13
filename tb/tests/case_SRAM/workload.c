// =============================================================================
// case_SRAM/workload.c — SRAM_rtl Unit Test Workload
//
// Test cases:
// TC01 Normal write then read (8 words)
// TC02 BWEB partial mask (protect high 32-bit, write low 32-bit)
// TC03 All-zeros / all-ones corner values
// TC04 Alternating bit patterns
// TC05 Address boundary (addr 0 and addr 127)
// =============================================================================

#include "workload.h"
#include "data.h"
#include "tb.h"

// ------------------------------------------------------------------
// Helper: write one 64-bit word to SRAM at address addr, mask = BWEB
// BWEB = 0 → write that bit (active-low mask)
// ------------------------------------------------------------------
static void sram_write(uint8_t addr, uint64_t data, uint64_t bweb) {
    set_A(addr);
    set_D(data);
    set_BWEB(bweb);
    set_CEB(0);
    set_WEB(0);
    tick(); // rising edge latches the write
    set_CEB(1); // deselect between accesses
    set_WEB(1);
}

// ------------------------------------------------------------------
// Helper: read one 64-bit word from SRAM at address addr
// Returns the value captured after the mandatory 1-cycle latency.
// ------------------------------------------------------------------
static uint64_t sram_read(uint8_t addr) {
    set_A(addr);
    set_CEB(0);
    set_WEB(1);
    tick(); // address presented on rising edge
    set_CEB(1); // deselect
    tick(); // wait 1-cycle read latency
    return get_Q();
}

// ------------------------------------------------------------------
// TC01 — Normal write then read
// ------------------------------------------------------------------
static void tc01_normal_write_read(void) {
    LOG("--- TC01: Normal Write/Read (%d words) ---", SRAM_TC01_WORDS);

    for (int i = 0; i < SRAM_TC01_WORDS; i++) {
        sram_write((uint8_t)i, tc01_data[i], 0x0000000000000000ULL); // write all bits
    }

    tick_n(2); // idle cycles between write and read phase

    for (int i = 0; i < SRAM_TC01_WORDS; i++) {
        uint64_t got = sram_read((uint8_t)i);
        CHECK(got == tc01_data[i],
              "TC01 addr=%d exp=0x%016llX got=0x%016llX",
              i, (unsigned long long)tc01_data[i], (unsigned long long)got);
    }
}

// ------------------------------------------------------------------
// TC02 — BWEB partial mask
// ------------------------------------------------------------------
static void tc02_partial_mask(void) {
    LOG("--- TC02: BWEB Partial Mask ---");

    // Step 1: write all-ones to the test address
    sram_write(SRAM_TC02_ADDR, tc02_full_val, 0x0000000000000000ULL);
    tick_n(2);

    // Step 2: overwrite only the low 32-bit using the partial mask
    sram_write(SRAM_TC02_ADDR, tc02_partial_val, tc02_mask);
    tick_n(2);

    // Step 3: read back and verify
    uint64_t got = sram_read(SRAM_TC02_ADDR);
    CHECK(got == tc02_expected,
          "TC02 exp=0x%016llX got=0x%016llX",
          (unsigned long long)tc02_expected, (unsigned long long)got);
}

// ------------------------------------------------------------------
// TC03 — All-zeros / all-ones
// ------------------------------------------------------------------
static void tc03_boundary_values(void) {
    LOG("--- TC03: All-zeros / All-ones ---");

    for (int i = 0; i < SRAM_TC03_WORDS; i++) {
        uint8_t addr = (uint8_t)(SRAM_TC03_BASE_ADDR + i);
        sram_write(addr, tc03_data[i], 0x0000000000000000ULL);
    }
    tick_n(2);
    for (int i = 0; i < SRAM_TC03_WORDS; i++) {
        uint8_t addr = (uint8_t)(SRAM_TC03_BASE_ADDR + i);
        uint64_t got = sram_read(addr);
        CHECK(got == tc03_data[i],
              "TC03 addr=%d exp=0x%016llX got=0x%016llX",
              addr, (unsigned long long)tc03_data[i], (unsigned long long)got);
    }
}

// ------------------------------------------------------------------
// TC04 — Alternating patterns
// ------------------------------------------------------------------
static void tc04_alternating_patterns(void) {
    LOG("--- TC04: Alternating Bit Patterns ---");

    for (int i = 0; i < SRAM_TC04_WORDS; i++) {
        uint8_t addr = (uint8_t)(SRAM_TC04_BASE_ADDR + i);
        sram_write(addr, tc04_data[i], 0x0000000000000000ULL);
    }
    tick_n(2);
    for (int i = 0; i < SRAM_TC04_WORDS; i++) {
        uint8_t addr = (uint8_t)(SRAM_TC04_BASE_ADDR + i);
        uint64_t got = sram_read(addr);
        CHECK(got == tc04_data[i],
              "TC04 addr=%d exp=0x%016llX got=0x%016llX",
              addr, (unsigned long long)tc04_data[i], (unsigned long long)got);
    }
}

// ------------------------------------------------------------------
// TC05 — Address boundary (addr 0 and addr 127)
// ------------------------------------------------------------------
static void tc05_address_boundary(void) {
    LOG("--- TC05: Address Boundary (addr 0 and 127) ---");

    sram_write(SRAM_TC05_ADDR_LO, tc05_data[0], 0x0000000000000000ULL);
    sram_write(SRAM_TC05_ADDR_HI, tc05_data[1], 0x0000000000000000ULL);
    tick_n(2);

    uint64_t got_lo = sram_read(SRAM_TC05_ADDR_LO);
    uint64_t got_hi = sram_read(SRAM_TC05_ADDR_HI);

    CHECK(got_lo == tc05_data[0],
          "TC05 addr=0 exp=0x%016llX got=0x%016llX",
          (unsigned long long)tc05_data[0], (unsigned long long)got_lo);
    CHECK(got_hi == tc05_data[1],
          "TC05 addr=127 exp=0x%016llX got=0x%016llX",
          (unsigned long long)tc05_data[1], (unsigned long long)got_hi);
}

// ------------------------------------------------------------------
// run_workload — called by main.c
// ------------------------------------------------------------------
void run_workload(void) {
    LOG("=== SRAM_rtl Unit Test Start ===");

    do_reset(2);

    tc01_normal_write_read();
    tc02_partial_mask();
    tc03_boundary_values();
    tc04_alternating_patterns();
    tc05_address_boundary();

    LOG("=== SRAM_rtl Unit Test End ===");
}
