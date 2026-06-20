// =============================================================================
// tb.cpp — Verilator C++ Harness (Fully Integrated Version)
// =============================================================================

#include <filesystem>
#include <ctime>
#include <cstring>
#include <string>
#include <verilated.h>
#include <verilated_fst_c.h>
#include "tb.h"

// ============================================================
// DUT Selection
// ============================================================
#if defined(case_SRAM)
#include "VSRAM_rtl.h"
using TopModule = VSRAM_rtl;
#elif defined(case_GLB)
#include "VGLB.h"
using TopModule = VGLB;
#elif defined(case_DMA)
#include "VDMA.h"
using TopModule = VDMA;
#elif defined(case_CTRL)
#include "Vcontroller.h"
using TopModule = Vcontroller;
#elif defined(case_MC)
#include "VMC.h"
using TopModule = VMC;
#elif defined(case_INTEGRATION)
#include "Vintegration.h"
using TopModule = Vintegration;
#else
#error "No CASE defined."
#endif

static TopModule* top = nullptr;
static VerilatedFstC* fst = nullptr;
uint64_t sim_time = 0;
int pass_count = 0;
int fail_count = 0;

static void tick_half() {
    top->eval();
    if (fst) fst->dump(sim_time);
    sim_time++;
}

// ============================================================
// Mock Behavior (For lower-level unit tests)
// ============================================================
#if defined(case_DMA) || defined(case_INTEGRATION)
// 開放給 DMA 與 INTEGRATION 共用的 DRAM 實體陣列與讀寫 API
uint32_t mock_glb_mem[16384];
void glb_mock_write(uint32_t byte_addr, uint32_t data) { mock_glb_mem[(byte_addr / 4) % 16384] = data; }
uint32_t glb_mock_read(uint32_t byte_addr) { return mock_glb_mem[(byte_addr / 4) % 16384]; }
#endif

#if defined(case_DMA)
static uint32_t delayed_glb_rdata = 0;
void glb_mock_tick() {
    top->glb_rdata = delayed_glb_rdata;
    if (top->glb_en) {
        if (top->glb_we) {
            mock_glb_mem[(top->glb_addr / 4) % 16384] = top->glb_wdata;
        } else {
            delayed_glb_rdata = mock_glb_mem[(top->glb_addr / 4) % 16384];
        }
    }
}
#endif

// ============================================================
// Core C API Functions
// ============================================================
extern "C" {

void tick() {
#if defined(case_SRAM)
    top->CLK = 0; tick_half();
    top->CLK = 1; tick_half();
#else
    #if defined(case_DMA)
    glb_mock_tick(); 
    #endif
    top->clk = 0; tick_half();
    top->clk = 1; tick_half();
#endif
}

void tick_n(int n) {
    for (int i = 0; i < n; i++) tick();
}

void do_reset(int cycles) {
#if defined(case_SRAM)
    top->CEB = 1; top->WEB = 1;
#else
    top->rst = 1; tick_n(cycles); top->rst = 0; return;
#endif
    tick_n(cycles);
}

void tb_init(int argc, char** argv, const char* test_name) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);
    top = new TopModule;

    #ifndef RESULT_DIR
    #define RESULT_DIR "results/fst"
    #endif
    std::filesystem::create_directories(RESULT_DIR);
    time_t now = time(nullptr);
    char ts[32];
    strftime(ts, sizeof(ts), "%Y%m%d_%H%M%S", localtime(&now));
    std::string fname = std::string(RESULT_DIR) + "/" + test_name + "_" + ts + ".fst";

    fst = new VerilatedFstC;
    top->trace(fst, 99);
    fst->open(fname.c_str());

    // 系統級接腳初始化
    #if defined(case_SRAM)
    top->CLK = 0; top->CEB = 1; top->WEB = 1; top->SLP = 0; top->DSLP = 0; top->SD = 0;
    #else
    top->clk = 0; top->rst = 0;
    #endif

    #if defined(case_DMA) || defined(case_INTEGRATION)
    std::memset(mock_glb_mem, 0, sizeof(mock_glb_mem));
    #endif

    #if defined(case_DMA)
    delayed_glb_rdata = 0;
    #endif

    // 模組狀態初始化分流
    #if defined(case_CTRL)
    top->asic_en = 0; top->DMA_done = 0; top->k_done = 0; top->PEA_A_ready = 0; top->PEA_B_ready = 0; top->ppu_done = 0; top->PEA_opsum_valid = 0;
    #elif defined(case_INTEGRATION)
    // 整合測試下，k_done, DMA_done 已被內部化，不需且不可對外設值
    top->asic_en = 0; top->PEA_A_ready = 0; top->PEA_B_ready = 0; top->ppu_done = 0;
    top->mock_pe_cfg_ready = 0; top->mock_pe_data_ready = 0;
    #elif defined(case_MC)
    top->mc_start = 0; top->mc_mode = 0; top->mc_glb_base_A = 0; top->mc_packet_count = 0;
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
    delete top; top = nullptr;
}

// ============================================================
// API Implementations by Case
// ============================================================

#if defined(case_SRAM)
void set_CEB (uint8_t val) { top->CEB = val; }
void set_WEB (uint8_t val) { top->WEB = val; }
void set_A (uint8_t val) { top->A = val; }
void set_D (uint64_t val) { top->D = val; }
void set_BWEB(uint64_t val) { top->BWEB = val; }
uint64_t get_Q (void) { return top->Q; }
#endif

#if defined(case_GLB)
void glb_set_EN (uint8_t val) { top->EN = val; }
void glb_set_WEB (uint8_t val) { top->WEB = val; }
void glb_set_WSTRB(uint8_t val) { top->WSTRB = val; }
void glb_set_A (uint32_t val) { top->A = val; }
void glb_set_DI (uint32_t val) { top->DI = val; }
uint32_t glb_get_DO (void) { return top->DO; }
#endif

#if defined(case_DMA)
void dma_set_en       (uint8_t val)  { top->DMA_en = val; }
void dma_set_mode     (uint8_t val)  { top->DMA_mode = val; }
void dma_set_dram_addr(uint32_t val) { top->DMA_DRAM_ADDR = val; }
void dma_set_glb_addr (uint32_t val) { top->DMA_GLB_ADDR = val; }
void dma_set_len      (uint32_t val) { top->DMA_len = val; }
uint8_t dma_get_done  (void)         { return top->DMA_done; }
uint8_t  dma_get_ARVALID(void) { return top->ARVALID; }
uint32_t dma_get_ARADDR (void) { return top->ARADDR; }
uint8_t  dma_get_ARLEN  (void) { return top->ARLEN; }
uint8_t  dma_get_AWVALID(void) { return top->AWVALID; }
uint32_t dma_get_AWADDR (void) { return top->AWADDR; }
uint8_t  dma_get_WVALID (void) { return top->WVALID; }
uint32_t dma_get_WDATA  (void) { return top->WDATA; }
uint8_t  dma_get_WLAST  (void) { return top->WLAST; }
uint8_t  dma_get_BREADY (void) { return top->BREADY; }
void axi_set_ARREADY (uint8_t val)  { top->ARREADY = val; }
void axi_set_RVALID  (uint8_t val)  { top->RVALID = val; }
void axi_set_RDATA   (uint32_t val) { top->RDATA = val; }
void axi_set_RRESP   (uint8_t val)  { top->RRESP = val; }
void axi_set_RLAST   (uint8_t val)  { top->RLAST = val; }
void axi_set_AWREADY (uint8_t val)  { top->AWREADY = val; }
void axi_set_WREADY  (uint8_t val)  { top->WREADY = val; }
void axi_set_BVALID  (uint8_t val)  { top->BVALID = val; }
void axi_set_BRESP   (uint8_t val)  { top->BRESP = val; }
#endif

// ------------------------------------------------------------
// CTRL 與 INTEGRATION 共用配置 API
// ------------------------------------------------------------
#if defined(case_CTRL) || defined(case_INTEGRATION)
void ctrl_set_asic_en(uint8_t val) { top->asic_en = val; }
void ctrl_set_A_fiber_base_addr(uint32_t val) { top->A_fiber_base_addr = val; }
void ctrl_set_B_fiber_base_addr(uint32_t val) { top->B_fiber_base_addr = val; }
void ctrl_set_C_tensor_base_addr(uint32_t val) { top->C_tensor_base_addr = val; }
void ctrl_set_GLB_A_base_addr(uint32_t val) { top->GLB_A_base_addr = val; }
void ctrl_set_GLB_B_base_addr(uint32_t val) { top->GLB_B_base_addr = val; }
void ctrl_set_GLB_C_base_addr(uint32_t val) { top->GLB_C_base_addr = val; }
void ctrl_set_comp_A_len_in(uint32_t val) { top->comp_A_len_in = val; }
void ctrl_set_comp_B_len_in(uint32_t val) { top->comp_B_len_in = val; }
void ctrl_set_comp_C_len_in(uint32_t val) { top->comp_C_len_in = val; }
void ctrl_set_N_tiles_in(uint32_t val) { top->N_tiles_in = val; }
void ctrl_set_K_tiles_in(uint32_t val) { top->K_tiles_in = val; }
void ctrl_set_M_tiles_in(uint32_t val) { top->M_tiles_in = val; }
void ctrl_set_packet_count_in(uint32_t val) { top->packet_count_in = val; }
void ctrl_set_operation_mode_in(uint8_t val) { top->operation_mode_in = val; }
void ctrl_set_e(uint8_t val) { top->e = val; }
void ctrl_set_p(uint8_t val) { top->p = val; }
void ctrl_set_q(uint8_t val) { top->q = val; }

void ctrl_set_PEA_A_ready(uint8_t val) { top->PEA_A_ready = val; }
void ctrl_set_PEA_B_ready(uint8_t val) { top->PEA_B_ready = val; }
void ctrl_set_ppu_done(uint8_t val) { top->ppu_done = val; }
uint8_t  ctrl_get_asic_done(void) { return top->asic_done; }

// ------------------------------------------------------------
// 分流處理：單測 (case_CTRL) vs 整合 (case_INTEGRATION)
// ------------------------------------------------------------
#if defined(case_CTRL)
void ctrl_set_DMA_done(uint8_t val) { top->DMA_done = val; }
void ctrl_set_k_done(uint8_t val)   { top->k_done = val; }
uint8_t  ctrl_get_DMA_en(void) { return top->DMA_en; }
uint8_t  ctrl_get_DMA_mode(void) { return top->DMA_mode; }
uint32_t ctrl_get_DMA_DRAM_ADDR(void) { return top->DMA_DRAM_ADDR; }
uint32_t ctrl_get_DMA_GLB_ADDR(void) { return top->DMA_GLB_ADDR; }
uint32_t ctrl_get_DMA_len(void) { return top->DMA_len; }
uint8_t  ctrl_get_mc_start(void) { return top->mc_start; }
uint8_t  ctrl_get_global_flush(void) { return top->global_flush; }

#elif defined(case_INTEGRATION)
void ctrl_set_DMA_done(uint8_t val) {}
void ctrl_set_k_done(uint8_t val)   {}
uint8_t  ctrl_get_DMA_en(void) { return 0; }
uint8_t  ctrl_get_DMA_mode(void) { return 0; }
uint32_t ctrl_get_DMA_DRAM_ADDR(void) { return 0; }
uint32_t ctrl_get_DMA_GLB_ADDR(void) { return 0; }
uint32_t ctrl_get_DMA_len(void) { return 0; }

uint8_t  ctrl_get_mc_start(void) { return top->obs_mc_start; }
uint8_t  ctrl_get_global_flush(void) { return top->obs_global_flush; }

// 綁定 Integration 獨有的 MC 交握觀測與 Mock 腳位
void intg_set_mock_pe_cfg_ready(uint8_t val) { top->mock_pe_cfg_ready = val; }
void intg_set_mock_pe_data_ready(uint8_t val) { top->mock_pe_data_ready = val; }
uint8_t  intg_get_pe_cfg_valid(void) { return top->obs_pe_cfg_valid; }
uint8_t  intg_get_pe_cfg_length(void) { return top->obs_pe_cfg_length; }
uint32_t intg_get_pe_cfg_bitmask(void) { return top->obs_pe_cfg_bitmask; }
uint8_t  intg_get_pe_data_valid(void) { return top->obs_pe_data_valid; }
uint32_t intg_get_pe_data_nzvalue(void) { return top->obs_pe_data_nzvalue; }
#endif
#endif

// ------------------------------------------------------------
// MC 單元測試專用 API
// ------------------------------------------------------------
#if defined(case_MC)
void mc_set_start(uint8_t val)         { top->mc_start = val; }
void mc_set_mode(uint8_t val)          { top->mc_mode = val; }
void mc_set_glb_base_A(uint32_t val)   { top->mc_glb_base_A = val; }
void mc_set_packet_count(uint32_t val) { top->mc_packet_count = val; }
void mc_set_glb_rdata_A(uint32_t val)  { top->glb_rdata_A = val; }
void mc_set_pe_cfg_ready(uint8_t val)  { top->pe_cfg_ready = val; }
void mc_set_pe_data_ready(uint8_t val) { top->pe_data_ready = val; }

uint8_t  mc_get_k_done(void)           { return top->k_done; }
uint8_t  mc_get_glb_ren_A(void)        { return top->mc_glb_ren_A; }
uint32_t mc_get_glb_addr_A(void)       { return top->mc_glb_addr_A; }
uint8_t  mc_get_pe_cfg_valid(void)     { return top->pe_cfg_valid; }
uint8_t  mc_get_pe_cfg_ready(void)     { return top->pe_cfg_ready; }
uint8_t  mc_get_pe_cfg_length(void)    { return top->pe_cfg_length; }
uint32_t mc_get_pe_cfg_bitmask(void)   { return top->pe_cfg_bitmask; }
uint8_t  mc_get_pe_data_valid(void)    { return top->pe_data_valid; }
uint8_t  mc_get_pe_data_ready(void)    { return top->pe_data_ready; }
uint32_t mc_get_pe_data_nzvalue(void)  { return top->pe_data_nzvalue; }
#endif

} // extern "C"
