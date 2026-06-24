// =============================================================================
// case_CTRL/workload.c — Controller FSM Unit Test
// =============================================================================

#include "workload.h"
#include "data.h"
#include "tb.h"
#include <stdio.h>

// -----------------------------------------------------------------------------
// 輔助函式：等待特定訊號變成預期值 (Timeout 保護)
// -----------------------------------------------------------------------------
static int wait_ctrl_signal(const char* name, uint8_t (*getter)(void), uint8_t exp, int max_cycles) {
    for (int i = 0; i < max_cycles; i++) {
        if (getter() == exp) return 1;
        tick();
    }
    printf("[FAIL @%llu] Timeout waiting for %s == %d\n", (unsigned long long)sim_time, name, exp);
    fail_count++;
    return 0;
}

// -----------------------------------------------------------------------------
// 輔助函式：動態 MKN 狀態追蹤器
// 負責送出假的 DMA_done / PPU_done，並驗證 Controller 有沒有走對路線
// -----------------------------------------------------------------------------
static void simulate_fsm_loop(uint32_t M, uint32_t K, uint32_t N) {
    for (uint32_t m = 0; m < M; m++) {
        
        // 1. 預期進入 S2: DMA FETCH A
        if (!wait_ctrl_signal("DMA_en (FETCH_A)", ctrl_get_DMA_en, 1, 50)) return;
        CHECK(ctrl_get_DMA_mode() == 0, "M=%d: DMA_mode should be 0 (FETCH_A)", m);
        
        // 模擬 DMA 搬完 A
        ctrl_set_DMA_done(1); tick(); ctrl_set_DMA_done(0);

        for (uint32_t k = 0; k < K; k++) {
            for (uint32_t n = 0; n < N; n++) {
                
                // 2. 預期進入 S3: DMA FETCH B
                if (!wait_ctrl_signal("DMA_en (FETCH_B)", ctrl_get_DMA_en, 1, 50)) return;
                CHECK(ctrl_get_DMA_mode() == 1, "M=%d,K=%d,N=%d: DMA_mode should be 1 (FETCH_B)", m, k, n);
                
                // 模擬 DMA 搬完 B
                ctrl_set_DMA_done(1); tick(); ctrl_set_DMA_done(0);

                // 3. FSM 等待 PEA_ready
                ctrl_set_PEA_A_ready(1);
                ctrl_set_PEA_B_ready(1);

                // 4. 預期進入 S5: MC_DISPATCH (mc_start pulse)
                if (!wait_ctrl_signal("mc_start", ctrl_get_mc_start, 1, 50)) return;
                tick(); // 消耗 pulse
                
                // 放下 ready，準備下一次迴圈
                ctrl_set_PEA_A_ready(0);
                ctrl_set_PEA_B_ready(0);

                // 5. FSM 在 S6 等待 k_done
                tick_n(2);
                ctrl_set_k_done(1); tick(); ctrl_set_k_done(0);

                // 6. 預期進入 S7: global_flush pulse
                if (!wait_ctrl_signal("global_flush", ctrl_get_global_flush, 1, 50)) return;

                // 7. FSM 在 S8 等待 ppu_done
                tick_n(2);
                ctrl_set_ppu_done(1); tick(); ctrl_set_ppu_done(0);
            }
        }
        
        // 8. 跑完 K*N 後，預期進入 S10: DMA WRITEBACK
        if (!wait_ctrl_signal("DMA_en (WRITEBACK)", ctrl_get_DMA_en, 1, 50)) return;
        CHECK(ctrl_get_DMA_mode() == 3, "M=%d: DMA_mode should be 3 (WRITEBACK)", m);
        
        // 模擬 DMA 寫回完成
        ctrl_set_DMA_done(1); tick(); ctrl_set_DMA_done(0);
    }
    
    // 9. 所有迴圈結束，預期進入 S11_DONE
    wait_ctrl_signal("asic_done", ctrl_get_asic_done, 1, 50);
}

// -----------------------------------------------------------------------------
// 共用測試進入點
// -----------------------------------------------------------------------------
static void run_tc(const char* tc_name, 
                   uint32_t a_base, uint32_t b_base, uint32_t c_base,
                   uint32_t a_len, uint32_t b_len, uint32_t c_len,
                   uint32_t m_tiles, uint32_t k_tiles, uint32_t n_tiles) {
    
    LOG("--- %s: M=%d, K=%d, N=%d ---", tc_name, m_tiles, k_tiles, n_tiles);

    // 1. 配置暫存器
    ctrl_set_A_fiber_base_addr(a_base);
    ctrl_set_B_fiber_base_addr(b_base);
    ctrl_set_C_tensor_base_addr(c_base);
    ctrl_set_GLB_A_base_addr(0x0000);
    ctrl_set_GLB_B_base_addr(0x0140);
    ctrl_set_GLB_C_base_addr(0x0280);
    
    ctrl_set_comp_A_len_in(a_len);
    ctrl_set_comp_B_len_in(b_len);
    ctrl_set_comp_C_len_in(c_len);
    
    ctrl_set_M_tiles_in(m_tiles);
    ctrl_set_K_tiles_in(k_tiles);
    ctrl_set_N_tiles_in(n_tiles);
    
    ctrl_set_packet_count_in(16);
    ctrl_set_operation_mode_in(0); // MODE_STD_IP
    tick_n(2);

    // 2. 啟動 FSM
    ctrl_set_asic_en(1);

    // 3. 追蹤並驗證 MKN 迴圈軌跡
    simulate_fsm_loop(m_tiles, k_tiles, n_tiles);

    // 4. 關閉 FSM
    ctrl_set_asic_en(0);
    tick_n(5);
}

// -----------------------------------------------------------------------------
// 任務進入點
// -----------------------------------------------------------------------------
void run_workload(void) {
    LOG("=== CTRL Unit Test Start ===");
    do_reset(4);

    run_tc("TC01 (Single)", TC01_A_DRAM_BASE, TC01_B_DRAM_BASE, TC01_C_DRAM_BASE,
           TC01_A_LEN, TC01_B_LEN, TC01_C_LEN, TC01_M_TILES, TC01_K_TILES, TC01_N_TILES);

    run_tc("TC02 (Nested N)", TC02_A_DRAM_BASE, TC02_B_DRAM_BASE, TC02_C_DRAM_BASE,
           TC02_A_LEN, TC02_B_LEN, TC02_C_LEN, TC02_M_TILES, TC02_K_TILES, TC02_N_TILES);

    run_tc("TC03 (Full MKN)", TC03_A_DRAM_BASE, TC03_B_DRAM_BASE, TC03_C_DRAM_BASE,
           TC03_A_LEN, TC03_B_LEN, TC03_C_LEN, TC03_M_TILES, TC03_K_TILES, TC03_N_TILES);

    LOG("=== CTRL Unit Test End ===");
}
