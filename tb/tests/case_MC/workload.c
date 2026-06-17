// =============================================================================
// case_MC/workload.c — MC Unit Test Workload (Pipeline Aligned)
// =============================================================================

#include "workload.h"
#include "data.h"
#include "tb.h"

void run_workload(void) {
    LOG("=== MC Unit Test Start ===");
    do_reset(4);

    // 1. 給定配置參數
    mc_set_mode(0);
    mc_set_glb_base_A(TEST_BASE_A);
    mc_set_glb_base_B(TEST_BASE_B);
    mc_set_packet_count(TEST_PKT_COUNT);
    tick();

    // 2. 發射 1-cycle mc_start 脈衝
    LOG(">> Pulsing mc_start");
    mc_set_start(1);
    tick();
    mc_set_start(0);

    // 3. 逐週期追蹤：分離 Address Phase 與 Data Phase
    for (uint32_t i = 0; i < TEST_PKT_COUNT; i++) {
        // [Address Phase] 檢查當前丟給 SRAM 的定址
        uint32_t exp_addr_A = TEST_BASE_A + (i * 4);
        uint32_t exp_addr_B = TEST_BASE_B + (i * 4);
        CHECK(mc_get_glb_addr_A() == exp_addr_A, "Beat %d: Addr_A exp=0x%04X got=0x%04X", i, exp_addr_A, mc_get_glb_addr_A());
        CHECK(mc_get_glb_addr_B() == exp_addr_B, "Beat %d: Addr_B exp=0x%04X got=0x%04X", i, exp_addr_B, mc_get_glb_addr_B());

        // 打一拍，推進 Pipeline (SRAM 內部開始讀取)
        tick();

        // [Data Phase] 檢查下一拍的資料有效訊號
        CHECK(mc_get_pe_data_valid() == 1, "Beat %d: pe_data_valid should be high", i);
    }

    // 4. 驗證結束拍：迴圈結束時剛好處於最後一筆 Data Phase，狀態機應進入 MC_DONE
    CHECK(mc_get_k_done() == 1, "k_done pulse missed at the end of loop");
    
    // 再打一拍回到 IDLE
    tick();
    CHECK(mc_get_pe_data_valid() == 0, "pe_data_valid failed to deassert post execution");
    CHECK(mc_get_k_done() == 0, "k_done held high for too long");

    tick_n(5);
    LOG("=== MC Unit Test End ===");
}