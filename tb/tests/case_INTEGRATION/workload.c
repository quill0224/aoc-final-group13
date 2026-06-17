// =============================================================================
// case_INTEGRATION/workload.c — Sub-system Integration Test (with Hardware MC)
// =============================================================================

#include "workload.h"
#include "data.h"
#include "tb.h"

static int wait_ctrl_signal(const char* name, uint8_t (*getter)(void), uint8_t exp, int max_cycles) {
    for (int i = 0; i < max_cycles; i++) {
        if (getter() == exp) return 1;
        tick();
    }
    printf("[FAIL @%llu] Timeout waiting for %s == %d\n", (unsigned long long)sim_time, name, exp);
    fail_count++;
    return 0;
}

static void tc01_system_e2e(void) {
    LOG("--- TC01: Full System Integration (M=%d, K=%d, N=%d) ---", INT_M_TILES, INT_K_TILES, INT_N_TILES);

    ctrl_set_A_fiber_base_addr(INT_A_DRAM_BASE);
    ctrl_set_B_fiber_base_addr(INT_B_DRAM_BASE);
    ctrl_set_C_tensor_base_addr(INT_C_DRAM_BASE);
    ctrl_set_GLB_A_base_addr(INT_GLB_A_BASE);
    ctrl_set_GLB_B_base_addr(INT_GLB_B_BASE);
    ctrl_set_GLB_C_base_addr(INT_GLB_C_BASE);
    
    ctrl_set_comp_A_len_in(INT_A_LEN);
    ctrl_set_comp_B_len_in(INT_B_LEN);
    ctrl_set_comp_C_len_in(INT_C_LEN);

    ctrl_set_M_tiles_in(INT_M_TILES);
    ctrl_set_K_tiles_in(INT_K_TILES);
    ctrl_set_N_tiles_in(INT_N_TILES);
    
    ctrl_set_packet_count_in(INT_PACKET_COUNT); // 設為 16 拍
    ctrl_set_operation_mode_in(INT_OP_MODE);

    ctrl_set_e(4); ctrl_set_p(2); ctrl_set_q(0);

    ctrl_set_PEA_A_ready(1);
    ctrl_set_PEA_B_ready(1);

    tick_n(2);
    LOG(">> CPU asserts asic_en = 1");
    ctrl_set_asic_en(1);

    for (uint32_t m = 0; m < INT_M_TILES; m++) {
        for (uint32_t k = 0; k < INT_K_TILES; k++) {
            for (uint32_t n = 0; n < INT_N_TILES; n++) {
                
                LOG(">> Monitoring Hardware Execution: [M_tile=%d, K_tile=%d, N_tile=%d]", m, k, n);

                if (!wait_ctrl_signal("mc_start", ctrl_get_mc_start, 1, 1000)) return;
                tick(); 
                
                // 【核心改變】完全不需要手動呼叫 ctrl_set_k_done() 了！
                // 真正的 MC 模組已經啟動，它會在背後自動計數 INT_PACKET_COUNT 拍。
                LOG("   - MC Hardware is autonomously generating addresses...");

                // 我們直接等待 MC 跑完後，Controller 自動切換進入 Flush 狀態。
                if (!wait_ctrl_signal("global_flush", ctrl_get_global_flush, 1, 500)) return;
                tick();

                tick_n(5);
                ctrl_set_ppu_done(1); tick(); ctrl_set_ppu_done(0);
            }
        }
    }

    LOG(">> Process completed. Waiting for Hardware Writeback and asic_done...");
    
    if (wait_ctrl_signal("asic_done", ctrl_get_asic_done, 1, 2000)) {
        LOG("[SUCCESS] Sub-system Integration Test with HARDWARE MC Passed Perfectly!");
        pass_count++;
    }
    
    ctrl_set_asic_en(0);
    tick_n(10);
}

void run_workload(void) {
    LOG("=== INTEGRATION Sub-system Test Start ===");
    do_reset(10);
    tc01_system_e2e();
    LOG("=== INTEGRATION Sub-system Test End ===");
}