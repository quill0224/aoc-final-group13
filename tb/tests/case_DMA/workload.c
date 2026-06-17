// =============================================================================
// case_DMA/workload.c — DMA Unit Test Workload
// =============================================================================

#include "workload.h"
#include "data.h"
#include "tb.h"
#include <stdint.h>
#include <string.h>
#include <stdio.h>

// ============================================================
// GLB shadow memory (mirrors physical GLB for verification)
// ============================================================
#define GLB_SHADOW_WORDS 1024
static uint32_t glb_shadow[GLB_SHADOW_WORDS];

static void glb_shadow_write(uint32_t byte_addr, uint32_t data) {
    uint32_t idx = (byte_addr >> 2) & (GLB_SHADOW_WORDS - 1);
    glb_shadow[idx] = data;
}

static uint32_t glb_shadow_read(uint32_t byte_addr) {
    uint32_t idx = (byte_addr >> 2) & (GLB_SHADOW_WORDS - 1);
    return glb_shadow[idx];
}

// ============================================================
// DRAM pattern generator
// ============================================================
static uint32_t dram_word(uint32_t base_addr, uint32_t abs_beat_idx) {
    return (base_addr & 0xFFFF0000U) | (abs_beat_idx & 0xFFFFU);
}

// ============================================================
// wait_for_signal
// ============================================================
static int wait_signal(const char* name, uint8_t (*getter)(void), int max_cycles) {
    for (int i = 0; i < max_cycles; i++) {
        if (getter()) return 1;
        tick();
    }
    printf("[FAIL @%llu] timeout waiting for %s\n", (unsigned long long)sim_time, name);
    fail_count++;
    return 0;
}

// ============================================================
// AXI Slave Stub (Read Burst)
// ============================================================
static int axi_slave_read_burst(uint32_t dram_base, uint32_t glb_base,
                                int beats, int ar_delay, int rvalid_gap, int start_beat) {
    if (!wait_signal("ARVALID", dma_get_ARVALID, 20)) return 0;

    CHECK(dma_get_ARADDR() == dram_base,
          "ARADDR exp=0x%08X got=0x%08X", dram_base, dma_get_ARADDR());
    CHECK(dma_get_ARLEN() == (uint8_t)(beats - 1),
          "ARLEN exp=%d got=%d", beats - 1, (int)dma_get_ARLEN());

    for (int d = 0; d < ar_delay; d++) {
        axi_set_ARREADY(0);
        tick();
    }
    axi_set_ARREADY(1);
    tick(); 
    axi_set_ARREADY(0);

    uint32_t cur_glb = glb_base;
    for (int b = 0; b < beats; b++) {
        if (rvalid_gap > 0 && b > 0 && (b % rvalid_gap) == 0) {
            axi_set_RVALID(0);
            tick();
        }
        uint32_t beat_data = dram_word(dram_base, start_beat + b);
        axi_set_RDATA(beat_data);
        axi_set_RRESP(0);
        axi_set_RLAST((b == beats - 1) ? 1 : 0);
        axi_set_RVALID(1);
        tick();

        glb_shadow_write(cur_glb, beat_data);
        cur_glb += 4;
    }
    axi_set_RVALID(0);
    axi_set_RLAST(0);
    return 1;
}

// ============================================================
// AXI Slave Stub (Write Burst)
// ============================================================
static int axi_slave_write_burst(uint32_t dram_base, uint32_t glb_base,
                                 int beats, int wready_period) {
    if (!wait_signal("AWVALID", dma_get_AWVALID, 20)) return 0;

    CHECK(dma_get_AWADDR() == dram_base,
          "AWADDR exp=0x%08X got=0x%08X", dram_base, dma_get_AWADDR());

    axi_set_AWREADY(1);
    tick();
    axi_set_AWREADY(0);

    int beats_received = 0;
    uint32_t cur_glb = glb_base;
    int stall_cnt = 0;

    while (beats_received < beats) {
        // [關鍵修正] 每次在 AXI Write 迴圈等待時，也要維持 GLB 的延遲讀取響應
        // 否則 DMA 的 FIFO 會因為沒有持續給資料而吸到 0
        static uint32_t delayed_glb_rdata = 0;
        glb_set_rdata(delayed_glb_rdata);
        
        if (dma_get_glb_en() && !dma_get_glb_we()) {
            delayed_glb_rdata = glb_shadow_read(dma_get_glb_addr());
        } else {
            delayed_glb_rdata = 0; // 避免舊資料殘留
        }

        if (wready_period > 0) {
            stall_cnt++;
            if (stall_cnt % wready_period == 0) axi_set_WREADY(1);
            else { axi_set_WREADY(0); tick(); continue; }
        } else {
            axi_set_WREADY(1);
        }

        if (!dma_get_WVALID()) { tick(); continue; }

        uint32_t wdata = dma_get_WDATA();
        uint8_t is_last = dma_get_WLAST();
        uint32_t expected = glb_shadow_read(cur_glb);

        CHECK(wdata == expected,
              "WDATA beat=%d exp=0x%08X got=0x%08X",
              beats_received, expected, wdata);

        if (beats_received == beats - 1) {
            CHECK(is_last == 1, "WLAST not asserted on last beat");
        } else {
            CHECK(is_last == 0, "WLAST asserted early");
        }

        cur_glb += 4;
        beats_received++;
        tick();
    }
    axi_set_WREADY(0);

    if (!wait_signal("BREADY", dma_get_BREADY, 10)) return 0;
    axi_set_BVALID(1);
    axi_set_BRESP(0);
    tick();
    axi_set_BVALID(0);

    return 1;
}

// ============================================================
// do_fetch
// ============================================================
static void do_fetch(uint32_t dram_base, uint32_t glb_base,
                     uint32_t len, int ar_delay, int rvalid_gap) {
    int total_beats = (int)(len / 4);

    dma_set_en(0);
    dma_set_mode(0);
    dma_set_dram_addr(dram_base);
    dma_set_glb_addr(glb_base);
    dma_set_len(len);
    tick();

    dma_set_en(1);

    int rem = total_beats;
    uint32_t cur_dram = dram_base;
    uint32_t cur_glb = glb_base;
    int abs_beat = 0;

    while (rem > 0) {
        int burst = (rem > 256) ? 256 : rem;
        axi_slave_read_burst(cur_dram, cur_glb, burst, ar_delay, rvalid_gap, abs_beat);
        cur_dram += (uint32_t)(burst * 4);
        cur_glb += (uint32_t)(burst * 4);
        rem -= burst;
        abs_beat += burst;
        ar_delay = 0;
    }

    int done_seen = 0;
    for (int t = 0; t < 30; t++) {
        if (dma_get_done()) { done_seen = 1; break; }
        tick();
    }
    CHECK(done_seen, "DMA_done not asserted after fetch");

    tick();
    dma_set_en(0);
    tick_n(2);
}

static void tc01_fetch_no_bp(void) {
    LOG("--- TC01: Fetch A tile 320B, no back-pressure ---");
    do_fetch(TC01_DRAM_BASE, TC01_GLB_BASE, TC01_LEN, 0, 0);

    for (int i = 0; i < (int)TC01_BEATS; i++) {
        uint32_t exp = dram_word(TC01_DRAM_BASE, (uint32_t)i);
        uint32_t got = glb_shadow_read((uint32_t)(TC01_GLB_BASE + i * 4));
        CHECK(got == exp, "TC01 GLB[%d] exp=0x%08X got=0x%08X", i, exp, got);
    }
}

static void tc02_fetch_arready_delay(void) {
    LOG("--- TC02: Fetch B tile 320B, ARREADY delay=%d ---", TC02_AR_DELAY);
    do_fetch(TC02_DRAM_BASE, TC02_GLB_BASE, TC02_LEN, TC02_AR_DELAY, 0);

    for (int i = 0; i < (int)TC02_BEATS; i++) {
        uint32_t exp = dram_word(TC02_DRAM_BASE, (uint32_t)i);
        uint32_t got = glb_shadow_read((uint32_t)(TC02_GLB_BASE + i * 4));
        CHECK(got == exp, "TC02 GLB[%d] exp=0x%08X got=0x%08X", i, exp, got);
    }
}

static void tc03_fetch_chunked(void) {
    LOG("--- TC03: Fetch 1280B with chunking (2 bursts) ---");
    do_fetch(TC03_DRAM_BASE, TC03_GLB_BASE, TC03_LEN, 0, 0);

    for (int i = 0; i < (int)TC03_BEATS; i++) {
        uint32_t exp = dram_word(TC03_DRAM_BASE, (uint32_t)i);
        uint32_t got = glb_shadow_read((uint32_t)(TC03_GLB_BASE + i * 4));
        CHECK(got == exp, "TC03 GLB[%d] exp=0x%08X got=0x%08X", i, exp, got);
    }
}

// ============================================================
// TC04 — Writeback 256B
// ============================================================
static void tc04_writeback_no_bp(void) {
    LOG("--- TC04: Writeback C tile 256B, no back-pressure ---");

    for (int i = 0; i < (int)TC04_BEATS; i++) {
        uint32_t byte_addr = (uint32_t)(TC04_GLB_BASE + i * 4);
        uint32_t val = tc04_glb_word((uint32_t)i);
        glb_shadow_write(byte_addr, val);
    }

    dma_set_en(0);
    dma_set_mode(3);
    dma_set_dram_addr(TC04_DRAM_BASE);
    dma_set_glb_addr(TC04_GLB_BASE);
    dma_set_len(TC04_LEN);
    tick();
    dma_set_en(1);

    int done_seen = 0;
    uint32_t delayed_glb_rdata = 0;

    for (int t = 0; t < 500 && !done_seen; t++) {
        // [關鍵修正] 完美的 1-cycle latency 模擬
        glb_set_rdata(delayed_glb_rdata);

        if (dma_get_glb_en() && !dma_get_glb_we()) {
            delayed_glb_rdata = glb_shadow_read(dma_get_glb_addr());
        } else {
            delayed_glb_rdata = 0;
        }

        tick();

        if (dma_get_AWVALID()) {
            axi_slave_write_burst(TC04_DRAM_BASE, TC04_GLB_BASE, (int)TC04_BEATS, 0);
        }

        if (dma_get_done()) done_seen = 1;
    }

    CHECK(done_seen, "TC04 DMA_done not asserted");
    tick();
    dma_set_en(0);
    tick_n(2);
}

// ============================================================
// TC05 — Writeback 256B with WREADY stall
// ============================================================
static void tc05_writeback_wready_stall(void) {
    LOG("--- TC05: Writeback 256B, WREADY stall period=%d ---", TC05_WREADY_PERIOD);

    for (int i = 0; i < (int)TC05_BEATS; i++) {
        glb_shadow_write((uint32_t)(TC05_GLB_BASE + i * 4), tc04_glb_word((uint32_t)i));
    }

    dma_set_en(0);
    dma_set_mode(3);
    dma_set_dram_addr(TC05_DRAM_BASE);
    dma_set_glb_addr(TC05_GLB_BASE);
    dma_set_len(TC05_LEN);
    tick();
    dma_set_en(1);

    int done_seen = 0;
    uint32_t delayed_glb_rdata = 0;

    for (int t = 0; t < 800 && !done_seen; t++) {
        // [關鍵修正] 完美的 1-cycle latency 模擬
        glb_set_rdata(delayed_glb_rdata);

        if (dma_get_glb_en() && !dma_get_glb_we()) {
            delayed_glb_rdata = glb_shadow_read(dma_get_glb_addr());
        } else {
            delayed_glb_rdata = 0;
        }

        tick();

        if (dma_get_AWVALID()) {
            axi_slave_write_burst(TC05_DRAM_BASE, TC05_GLB_BASE, (int)TC05_BEATS, TC05_WREADY_PERIOD);
        }

        if (dma_get_done()) done_seen = 1;
    }

    CHECK(done_seen, "TC05 DMA_done not asserted");
    tick();
    dma_set_en(0);
    tick_n(2);
}

void run_workload(void) {
    LOG("=== DMA Unit Test Start ===");

    memset(glb_shadow, 0, sizeof(glb_shadow));
    do_reset(4);

    tc01_fetch_no_bp();
    tc02_fetch_arready_delay();
    tc03_fetch_chunked();
    tc04_writeback_no_bp();
    tc05_writeback_wready_stall();

    LOG("=== DMA Unit Test End ===");
}
