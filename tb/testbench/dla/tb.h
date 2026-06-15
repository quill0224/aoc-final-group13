#pragma once
#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================
// Global counters (defined in tb.cpp, visible to C workloads)
// ============================================================
extern uint64_t sim_time;
extern int pass_count;
extern int fail_count;

// ============================================================
// Core TB API (clock, reset, lifecycle)
// ============================================================
void tb_init(int argc, char** argv, const char* test_name);
void tb_close(void);
void tick(void);
void tick_n(int n);
void do_reset(int cycles);

// ============================================================
// SRAM pin API
// ============================================================
#if defined(case_SRAM)
void set_CEB(uint8_t val);
void set_WEB(uint8_t val);
void set_A(uint8_t val);
void set_D(uint64_t val);
void set_BWEB(uint64_t val);
uint64_t get_Q(void);
#endif

// ============================================================
// GLB pin API (add when implementing case_GLB)
// ============================================================
#if defined(case_GLB)
void glb_set_EN(uint8_t val);
void glb_set_WEB(uint8_t val);
void glb_set_WSTRB(uint8_t val);
void glb_set_A(uint32_t val);
void glb_set_DI(uint32_t val);
uint32_t glb_get_DO(void);
#endif

// ============================================================
// DMA pin API (add when implementing case_DMA)
// ============================================================
#if defined(case_DMA)
void dma_set_en(uint8_t val);
void dma_set_mode(uint8_t val);
void dma_set_dram_addr(uint32_t val);
void dma_set_glb_addr(uint32_t val);
void dma_set_len(uint32_t val);
uint8_t dma_get_done(void);
#endif

// ============================================================
// Logging & Check macros
// ============================================================
#define LOG(msg, ...) \
printf("[TB @%llu] " msg "\n", (unsigned long long)sim_time, ##__VA_ARGS__)

#define CHECK(cond, msg, ...) \
do { \
if (!(cond)) { \
printf("[FAIL @%llu] " msg "\n", \
(unsigned long long)sim_time, ##__VA_ARGS__); \
fail_count++; \
} else { \
pass_count++; \
} \
} while (0)

#ifdef __cplusplus
}
#endif
