#include "tb.h"
#include <stdint.h>

void issue_asic_command(uint32_t cmd) {
    uint8_t start   = (cmd >> 31) & 0x1;
    uint8_t mode    = (cmd >> 29) & 0x3;
    uint8_t m_tiles = (cmd >> 16) & 0x7F;
    uint16_t k_tiles = (cmd >> 6)  & 0x3FF;
    uint8_t n_tiles = cmd         & 0x3F;

    ctrl_set_operation_mode_in(mode);
    ctrl_set_M_tiles_in(m_tiles);
    ctrl_set_K_tiles_in(k_tiles);
    ctrl_set_N_tiles_in(n_tiles);

    if (start) {
        LOG(">> 發送指令: Start=%d, Mode=%d, M=%d, K=%d, N=%d", start, mode, m_tiles, k_tiles, n_tiles);
        ctrl_set_asic_en(1);
        tick_n(10);
        ctrl_set_asic_en(0);
    }
}

extern "C" void run_workload(uint32_t compressed_bytes) {
    LOG("=== MC 稀疏資料流交握驗證 ===");
    do_reset(10);

    // 位址對齊：確保 DMA 抓取的位址對應到 dram_test.hex 的載入起始點
    ctrl_set_A_fiber_base_addr(0x0000); 
    ctrl_set_B_fiber_base_addr(0x2000); 
    ctrl_set_GLB_A_base_addr(0x0000);
    ctrl_set_GLB_B_base_addr(0x0140);
    
    ctrl_set_comp_A_len_in(320);
    ctrl_set_comp_B_len_in(320); 
    ctrl_set_comp_C_len_in(256);
    ctrl_set_packet_count_in(16); 

    intg_set_mock_pe_cfg_ready(1);
    intg_set_mock_pe_data_ready(1);
    ctrl_set_PEA_A_ready(1); 
    ctrl_set_PEA_B_ready(1);
    ctrl_set_ppu_done(1);    
    tick();

    issue_asic_command(0xA0010041);

    int timeout = 5000; 
    int cfg_cnt = 0;
    int payload_cnt = 0;

    while (timeout > 0) {
        intg_set_mock_pe_cfg_ready(1);
        intg_set_mock_pe_data_ready(1);

        if (intg_get_pe_cfg_valid()) {
            cfg_cnt++;
            payload_cnt = 0;
            LOG(">> [MC->PE] Config 解析 (封包 %03d): Length=%d, Bitmask=0x%04X",
                cfg_cnt, intg_get_pe_cfg_length(), intg_get_pe_cfg_bitmask());
        }

        if (intg_get_pe_data_valid()) {
            LOG("   -> [MC->PE] NZ Data 傳輸 (Word %d): 0x%08X", payload_cnt, intg_get_pe_data_nzvalue());
            payload_cnt++;
        }

        if (ctrl_get_asic_done()) {
            LOG(">> ASIC 運算完成。");
            break;
        }
        tick(); timeout--;
    }
    tick_n(10);
}