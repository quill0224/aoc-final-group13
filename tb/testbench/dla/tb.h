#pragma once
#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

extern uint64_t sim_time;
extern int pass_count;
extern int fail_count;

void tb_init(int argc, char** argv, const char* test_name);
void tb_close(void);
void tick(void);
void tick_n(int n);
void do_reset(int cycles);

#if defined(case_SRAM)
void set_CEB(uint8_t val);
void set_WEB(uint8_t val);
void set_A(uint8_t val);
void set_D(uint64_t val);
void set_BWEB(uint64_t val);
uint64_t get_Q(void);
#endif

#if defined(case_GLB)
void glb_set_EN(uint8_t val);
void glb_set_WEB(uint8_t val);
void glb_set_WSTRB(uint8_t val);
void glb_set_A(uint32_t val);
void glb_set_DI(uint32_t val);
uint32_t glb_get_DO(void);
#endif

#if defined(case_DMA) || defined(case_INTEGRATION)
// 開放給 DMA 與 INTEGRATION 共用的模擬 DRAM 讀寫介面
void glb_mock_write(uint32_t byte_addr, uint32_t data);
uint32_t glb_mock_read(uint32_t byte_addr);
#endif

#if defined(case_DMA)
void dma_set_en(uint8_t val);
void dma_set_mode(uint8_t val);
void dma_set_dram_addr(uint32_t val);
void dma_set_glb_addr(uint32_t val);
void dma_set_len(uint32_t val);
uint8_t dma_get_done(void);
uint8_t  dma_get_ARVALID(void);
uint32_t dma_get_ARADDR(void);
uint8_t  dma_get_ARLEN(void);
uint8_t  dma_get_AWVALID(void);
uint32_t dma_get_AWADDR(void);
uint8_t  dma_get_WVALID(void);
uint32_t dma_get_WDATA(void);
uint8_t  dma_get_WLAST(void);
uint8_t  dma_get_BREADY(void);
void axi_set_ARREADY(uint8_t val);
void axi_set_RVALID(uint8_t val);
void axi_set_RDATA(uint32_t val);
void axi_set_RRESP(uint8_t val);
void axi_set_RLAST(uint8_t val);
void axi_set_AWREADY(uint8_t val);
void axi_set_WREADY(uint8_t val);
void axi_set_BVALID(uint8_t val);
void axi_set_BRESP(uint8_t val);
#endif

#if defined(case_CTRL) || defined(case_INTEGRATION)
void ctrl_set_asic_en(uint8_t val);
void ctrl_set_A_fiber_base_addr(uint32_t val);
void ctrl_set_B_fiber_base_addr(uint32_t val);
void ctrl_set_C_tensor_base_addr(uint32_t val);
void ctrl_set_GLB_A_base_addr(uint32_t val);
void ctrl_set_GLB_B_base_addr(uint32_t val);
void ctrl_set_GLB_C_base_addr(uint32_t val);
void ctrl_set_comp_A_len_in(uint32_t val);
void ctrl_set_comp_B_len_in(uint32_t val);
void ctrl_set_comp_C_len_in(uint32_t val);

// void ctrl_set_N_tiles_in(uint32_t val);
// void ctrl_set_K_tiles_in(uint32_t val);
// void ctrl_set_M_tiles_in(uint32_t val);
// void ctrl_set_packet_count_in(uint32_t val);
// void ctrl_set_operation_mode_in(uint8_t val);
void ctrl_set_asic_cmd_in(uint32_t val);

void ctrl_set_e(uint8_t val);
void ctrl_set_p(uint8_t val);
void ctrl_set_q(uint8_t val);
void ctrl_set_DMA_done(uint8_t val);
void ctrl_set_k_done(uint8_t val);
void ctrl_set_PEA_A_ready(uint8_t val);
void ctrl_set_PEA_B_ready(uint8_t val);
void ctrl_set_ppu_done(uint8_t val);
uint8_t  ctrl_get_asic_done(void);
uint8_t  ctrl_get_DMA_en(void);
uint8_t  ctrl_get_DMA_mode(void);
uint32_t ctrl_get_DMA_DRAM_ADDR(void);
uint32_t ctrl_get_DMA_GLB_ADDR(void);
uint32_t ctrl_get_DMA_len(void);
uint8_t  ctrl_get_mc_start(void);
uint8_t  ctrl_get_global_flush(void);
#endif

// ------------------------------------------------------------
// INTEGRATION 專屬擴充 API (對接 MC 交握觀測腳位)
// ------------------------------------------------------------
#if defined(case_INTEGRATION)
void intg_set_mock_pe_cfg_ready(uint8_t val);
void intg_set_mock_pe_data_ready(uint8_t val);
uint8_t  intg_get_pe_cfg_valid(void);
uint8_t  intg_get_pe_cfg_length(void);
uint32_t intg_get_pe_cfg_bitmask(void);
uint8_t  intg_get_pe_data_valid(void);
uint32_t intg_get_pe_data_nzvalue(void);
#endif

#if defined(case_MC)
void mc_set_start(uint8_t val);
void mc_set_mode(uint8_t val);
void mc_set_glb_base_A(uint32_t val);
void mc_set_packet_count(uint32_t val);
void mc_set_glb_rdata_A(uint32_t val);
void mc_set_pe_cfg_ready(uint8_t val);
void mc_set_pe_data_ready(uint8_t val);

uint8_t  mc_get_k_done(void);
uint8_t  mc_get_glb_ren_A(void);
uint32_t mc_get_glb_addr_A(void);
uint8_t  mc_get_pe_cfg_valid(void);
uint8_t  mc_get_pe_cfg_ready(void);   
uint8_t  mc_get_pe_cfg_length(void);
uint32_t mc_get_pe_cfg_bitmask(void);
uint8_t  mc_get_pe_data_valid(void);
uint8_t  mc_get_pe_data_ready(void);  
uint32_t mc_get_pe_data_nzvalue(void);
#endif

#define LOG(msg, ...) \
    printf("[TB @%llu] " msg "\n", (unsigned long long)sim_time, ##__VA_ARGS__)

#define CHECK(cond, msg, ...) \
    do { \
        if (!(cond)) { \
            printf("[FAIL @%llu] " msg "\n", (unsigned long long)sim_time, ##__VA_ARGS__); \
            fail_count++; \
        } else { \
            pass_count++; \
        } \
    } while (0)

#ifdef __cplusplus
}
#endif
