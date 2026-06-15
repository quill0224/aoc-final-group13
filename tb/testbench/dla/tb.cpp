// =============================================================================
// tb.cpp — Verilator C++ Harness
//
// Responsibilities:
// - Instantiate the Verilated DUT (selected at compile time via -Dcase_XXX)
// - Drive clock, dump FST waveform with timestamped filename
// - Expose a C-compatible API (extern "C") for pure-C workload files
//
// Adding a new case:
// 1. Add a new #elif block below to include the right Verilated header
// 2. Add pin API functions at the bottom guarded by #if defined(case_XXX)
// 3. Expose new API prototypes in tb.h
// =============================================================================

#include <filesystem>
#include <ctime>
#include <cstring>
#include <string>
#include <verilated.h>
#include <verilated_fst_c.h>
#include "tb.h"

// ============================================================
// DUT Selection — include the correct Verilator-generated header
// Verilator places generated headers in OBJ_DIR, which is added
// to the include path via -CFLAGS -I$(OBJ_DIR) in the Makefile.
// ============================================================
#if defined(case_SRAM)
#include "VSRAM_rtl.h"
using TopModule = VSRAM_rtl;

#elif defined(case_GLB)
#include "VGLB.h"
using TopModule = VGLB;

#elif defined(case_DMA)
#include "Vdma.h"
using TopModule = Vdma;

#elif defined(case_CTRL)
#include "Vtop_controller.h"
using TopModule = Vtop_controller;

#elif defined(case_INTEGRATION)
#include "Vtop_integration.h"
using TopModule = Vtop_integration;

#else
#error "No CASE defined. Compile with -Dcase_SRAM / -Dcase_GLB / etc."
#endif

// ============================================================
// Global State (declared extern in tb.h)
// ============================================================
static TopModule* top = nullptr;
static VerilatedFstC* fst = nullptr;

uint64_t sim_time = 0;
int pass_count = 0;
int fail_count = 0;

// ============================================================
// Internal: advance simulation by half a clock period
// ============================================================
static void tick_half() {
top->eval();
if (fst) fst->dump(sim_time);
sim_time++;
}

// ============================================================
// extern "C" API Implementation
// ============================================================
extern "C" {

// ----------------------------------------------------------
// Clock
// SRAM uses CLK; all other modules use clk (lowercase).
// ----------------------------------------------------------
void tick() {
#if defined(case_SRAM)
top->CLK = 0; tick_half();
top->CLK = 1; tick_half();
#else
top->clk = 0; tick_half();
top->clk = 1; tick_half();
#endif
}

void tick_n(int n) {
for (int i = 0; i < n; i++) tick();
}

// ----------------------------------------------------------
// Reset
// Each module's reset signal is named differently.
// Add new cases here as modules are integrated.
// ----------------------------------------------------------
void do_reset(int cycles) {
#if defined(case_SRAM)
top->CEB = 1;
top->WEB = 1;
#elif defined(case_CTRL)
top->rst = 1;
tick_n(cycles);
top->rst = 0;
return;
#else
top->rst = 1;
tick_n(cycles);
top->rst = 0;
return;
#endif
tick_n(cycles);
}

// ----------------------------------------------------------
// Lifecycle
// ----------------------------------------------------------
void tb_init(int argc, char** argv, const char* test_name) {
Verilated::commandArgs(argc, argv);
Verilated::traceEverOn(true);

top = new TopModule;

// Build timestamped waveform filename
// RESULT_DIR is injected by Makefile via -DRESULT_DIR="..."
#ifndef RESULT_DIR
#define RESULT_DIR "results/fst"
#endif
std::filesystem::create_directories(RESULT_DIR);

time_t now = time(nullptr);
char ts[32];
strftime(ts, sizeof(ts), "%Y%m%d_%H%M%S", localtime(&now));

std::string fname = std::string(RESULT_DIR) + "/"
+ test_name + "_" + ts + ".fst";

fst = new VerilatedFstC;
top->trace(fst, 99);
fst->open(fname.c_str());

printf("[TB] Waveform → %s\n", fname.c_str());

// Default pin states
#if defined(case_SRAM)
top->CLK = 0;
top->CEB = 1; // deselected
top->WEB = 1; // read (inactive)
top->SLP = 0;
top->DSLP = 0;
top->SD = 0;
#else
top->clk = 0;
top->rst = 0;
#endif
}

void tb_close() {
tick_n(5);

if (fst) { fst->close(); delete fst; fst = nullptr; }

int total = pass_count + fail_count;
printf("\n========================================\n");
printf(" SIMULATION RESULT\n");
printf(" PASS : %d / %d\n", pass_count, total);
printf(" FAIL : %d / %d\n", fail_count, total);
printf("========================================\n");

delete top;
top = nullptr;
}

// ============================================================
// SRAM Pin API
// ============================================================
#if defined(case_SRAM)
void set_CEB (uint8_t val) { top->CEB = val; }
void set_WEB (uint8_t val) { top->WEB = val; }
void set_A (uint8_t val) { top->A = val; }
void set_D (uint64_t val) { top->D = val; }
void set_BWEB(uint64_t val) { top->BWEB = val; }
uint64_t get_Q (void) { return top->Q; }
#endif

// ============================================================
// GLB Pin API (implement when adding case_GLB)
// ============================================================
#if defined(case_GLB)
void glb_set_EN (uint8_t val) { top->EN = val; }
void glb_set_WEB (uint8_t val) { top->WEB = val; }
void glb_set_WSTRB(uint8_t val) { top->WSTRB = val; }
void glb_set_A (uint32_t val) { top->A = val; }
void glb_set_DI (uint32_t val) { top->DI = val; }
uint32_t glb_get_DO (void) { return top->DO; }
#endif

// ============================================================
// DMA Pin API (implement when adding case_DMA)
// ============================================================
#if defined(case_DMA)
void dma_set_en (uint8_t val) { top->DMA_en = val; }
void dma_set_mode (uint8_t val) { top->DMA_mode = val; }
void dma_set_dram_addr(uint32_t val) { top->DMA_DRAM_ADDR = val; }
void dma_set_glb_addr (uint32_t val) { top->DMA_GLB_ADDR = val; }
void dma_set_len (uint32_t val) { top->DMA_len = val; }
uint8_t dma_get_done (void) { return top->DMA_done; }
#endif

} // extern "C"
