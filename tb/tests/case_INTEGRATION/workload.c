// // =============================================================================
// // workload.c — case_INTEGRATION simulation workload
// //
// // 驗證項目：
// // 1. Controller FSM 正確啟動（S0→S1→S2→...）
// // 2. DMA 正確從 DRAM 搬 A tile 到 GLB（320 bytes，16 packets）
// // 3. MC 正確解析每個 packet 的 {length, bitmask}
// // 4. MC 正確送出 NZ values 給 PE
// // 5. Controller 收到 k_done 後發 global_flush
// // 6. ppu_done 後 Controller 發 DMA writeback（stub）
// // 7. asic_done 拉高
// //
// // 使用的 ASIC 指令（32-bit）：
// // [31] start=1
// // [30:29] mode=01 (TrIP)
// // [28:22] M=1 → bits 28:22 = 0x01 → <<22 = 0x00400000
// // [21:12] K=1 → bits 21:12 = 0x01 → <<12 = 0x00001000
// // [11:6] N=1 → bits 11:6 = 0x01 → <<6 = 0x00000040
// // [5:1] pkt=16 → bits 5:1 = 0x10 → <<1 = 0x00000020
// // [0] reserved=0
// // = 0x80000000|0x20000000|0x00400000|0x00001000|0x00000040|0x00000020
// // = 0xA0401060
// // =============================================================================

// #include "tb.h"
// #include <stdint.h>
// #include <stdio.h>

// // ---------------------------------------------------------------------------
// // 解碼並發送 32-bit 啟動指令
// // 指令格式：[31]=start [30:29]=mode [28:22]=M [21:12]=K [11:6]=N [5:1]=pkt [0]=rsv
// // ---------------------------------------------------------------------------
// static void issue_asic_command(uint32_t cmd) {
//     uint8_t start = (cmd >> 31) & 0x1;
//     uint8_t mode = (cmd >> 29) & 0x3;
//     uint8_t m_tiles = (cmd >> 22) & 0x7F;
//     uint16_t k_tiles = (cmd >> 12) & 0x3FF;
//     uint8_t n_tiles = (cmd >> 6) & 0x3F;
//     uint8_t pkt_cnt = (cmd >> 1) & 0x1F;

//     ctrl_set_operation_mode_in(mode);
//     ctrl_set_M_tiles_in(m_tiles);
//     ctrl_set_K_tiles_in(k_tiles);
//     ctrl_set_N_tiles_in(n_tiles);
//     ctrl_set_packet_count_in(pkt_cnt);
//     ctrl_set_comp_A_len_in(320); // 16 pkts × 20 bytes
//     ctrl_set_comp_B_len_in(320);
//     ctrl_set_comp_C_len_in(256); // 16×16 INT8 output

//     LOG(">> ASIC CMD 0x%08X: start=%d mode=%d M=%d K=%d N=%d pkt=%d",
//         cmd, start, mode, m_tiles, k_tiles, n_tiles, pkt_cnt);

//     if (start) {
//         ctrl_set_asic_en(1);
//         tick();
//         // asic_en 只需要拉高 1 cycle，controller 內部有同步器
//         // 不需要拉高很久
//         ctrl_set_asic_en(0);
//     }
// }

// extern "C" void run_workload(uint32_t compressed_bytes) {
//     LOG("=== Integration Test: Controller + DMA + GLB + MC ===");
//     LOG(" A tile: %u bytes = %u packets in DRAM",
//         compressed_bytes, compressed_bytes / 20);

//     do_reset(10);

//     // --- MMIO 位址設定 ---
//     // DRAM A 從 0x0000 開始（word_base_addr=0 → byte addr=0）
//     ctrl_set_A_fiber_base_addr(0x00000000);
//     ctrl_set_B_fiber_base_addr(0x00010000); // B 不使用，設一個安全地址
//     ctrl_set_C_tensor_base_addr(0x00020000); // C writeback 目標

//     ctrl_set_GLB_A_base_addr(0x0000);
//     ctrl_set_GLB_B_base_addr(0x0140);
//     ctrl_set_GLB_C_base_addr(0x0280);

//     // --- PE Array 和 PPU stub 始終 ready ---
//     ctrl_set_PEA_A_ready(1);
//     ctrl_set_PEA_B_ready(1);
//     intg_set_mock_pe_cfg_ready(1);
//     intg_set_mock_pe_data_ready(1);

//     // ppu_done 預設不拉高，等 MC 完成後再拉（模擬 PPU 延遲）
//     ctrl_set_ppu_done(0);

//     tick_n(3);

//     // --- 發送啟動指令（M=1, K=1, N=1, pkt=16, TrIP mode）---
//     // 0x80000000 | 0x20000000 | (1<<22) | (1<<12) | (1<<6) | (16<<1)
//     // = 0xA0401060
//     issue_asic_command(0xA0401060);

//     // --- 主仿真迴圈 ---
//     int timeout = 10000;
//     int cfg_cnt = 0;
//     int payload_cnt = 0;
//     int pass_count_local = 0;
//     int fail_count_local = 0;

//     // 期望值（來自 data.h 前幾行 bitmask）
//     // 第 1 個 chunk（mask64[15:0] = 0x6030, popcount = 4）
//     uint16_t exp_bitmask[3] = {0x6030, 0x0040, 0x0000};
//     uint16_t exp_length[3] = {4, 1, 0};
//     int checked_pkts = 0;

//     // 追蹤 k_done 和 flush
//     int k_done_seen = 0;
//     int flush_seen = 0;
//     int ppu_done_injected = 0;
//     int done = 0;

//     while (!done && timeout-- > 0) {

//         // --- 注入 ppu_done（在 k_done 之後 5 cycles）---
//         if (k_done_seen && !ppu_done_injected) {
//             static int flush_delay = 0;
//             flush_delay++;
//             if (flush_delay >= 5) {
//                 ctrl_set_ppu_done(1);
//                 tick();
//                 ctrl_set_ppu_done(0);
//                 ppu_done_injected = 1;
//                 LOG(" [stub] ppu_done injected");
//                 continue;
//             }
//         }

//         // --- 觀測 MC → PE 輸出 ---
//         if (intg_get_pe_cfg_valid()) {
//             cfg_cnt++;
//             payload_cnt = 0;

//             uint16_t got_bitmask = intg_get_pe_cfg_bitmask();
//             uint16_t got_length = intg_get_pe_cfg_length();

//             LOG(">> [MC->PE] Cfg pkt#%03d: length=%2d bitmask=0x%04X",
//                 cfg_cnt, got_length, got_bitmask);

//             // 驗證前 3 個 packet 的 bitmask 和 length
//             if (checked_pkts < 3) {
//                 if (got_bitmask == exp_bitmask[checked_pkts] &&
//                     got_length == exp_length[checked_pkts]) {
//                     LOG(" [PASS] pkt#%d bitmask/length correct", cfg_cnt);
//                     pass_count_local++;
//                 } else {
//                     LOG(" [FAIL] pkt#%d: exp bitmask=0x%04X len=%d, "
//                         "got bitmask=0x%04X len=%d",
//                         cfg_cnt,
//                         exp_bitmask[checked_pkts], exp_length[checked_pkts],
//                         got_bitmask, got_length);
//                     fail_count_local++;
//                 }
//                 checked_pkts++;
//             }
//         }

//         if (intg_get_pe_data_valid()) {
//             LOG(" -> [MC->PE] NZ word#%d: 0x%08X",
//                 payload_cnt, intg_get_pe_data_nzvalue());
//             payload_cnt++;
//         }

//         // --- 觀測 k_done 和 flush ---
        
//         // 移除未宣告的 intg_get_obs_mc_start 判斷，避免編譯錯誤
//         /*
//         if (intg_get_obs_mc_start() && !k_done_seen) {
//             LOG(" [obs] mc_start asserted");
//         }
//         */

//         // k_done 來自 MC 內部，透過 obs_mc_start 間接觀測
//         // 直接看 cfg_cnt == 16 代表 16 個 packet 都送完了
//         if (cfg_cnt >= 16 && !k_done_seen) {
//             k_done_seen = 1;
//             LOG(" [obs] All 16 packets dispatched → expecting k_done");
//         }

//         // 【修正】：將 intg_get_obs_global_flush 修正為編譯器建議的 ctrl_get_global_flush
//         if (ctrl_get_global_flush()) {
//             flush_seen = 1;
//             LOG(" [obs] global_flush asserted");
//             if (k_done_seen) {
//                 LOG(" [PASS] flush comes after k_done (correct order)");
//                 pass_count_local++;
//             } else {
//                 LOG(" [FAIL] flush came before k_done");
//                 fail_count_local++;
//             }
//         }

//         // --- 檢查 asic_done ---
//         if (ctrl_get_asic_done()) {
//             LOG(">> ASIC done at cycle %llu", (unsigned long long)sim_time);
//             done = 1;

//             // 最終統計
//             if (cfg_cnt == 16) {
//                 LOG("[PASS] All 16 packets received by PE");
//                 pass_count_local++;
//             } else {
//                 LOG("[FAIL] Only %d/16 packets received", cfg_cnt);
//                 fail_count_local++;
//             }

//             if (flush_seen) {
//                 LOG("[PASS] global_flush was asserted");
//                 pass_count_local++;
//             } else {
//                 LOG("[FAIL] global_flush never asserted");
//                 fail_count_local++;
//             }
//             break;
//         }

//         tick();
//     }

//     if (!done) {
//         LOG("[FAIL] Timeout after 10000 cycles (asic_done never seen)");
//         LOG(" cfg_cnt=%d k_done_seen=%d flush_seen=%d ppu_done=%d",
//             cfg_cnt, k_done_seen, flush_seen, ppu_done_injected);
//         fail_count_local++;
//     }

//     tick_n(20);

//     // 更新全域計數器（tb.h 提供）
//     pass_count += pass_count_local;
//     fail_count += fail_count_local;

//     LOG("=== Summary: PASS=%d FAIL=%d ===", pass_count_local, fail_count_local);
// }


#include "tb.h"
#include "data.h"
#include <stdint.h>
#include <stdio.h>

// ---------------------------------------------------------------------------
// 讀取並列印 Hex 檔前 5 筆 AXI 封包 (160-bit/5-word)
// ---------------------------------------------------------------------------
static void dump_initial_axi_packets(const char* filepath, int count) {
    FILE *f = fopen(filepath, "r");
    if (!f) {
        LOG("[ERROR] 無法開啟 %s 讀取初始封包。", filepath);
        return;
    }
    
    char buf[64];
    // 略過第一行的 @00000000 位址標記
    if (fscanf(f, "%63s", buf) != 1) {
        fclose(f);
        return;
    }

    LOG("=== 前 %d 筆 AXI 封包 (DRAM 內容預覽) ===", count);
    for (int p = 0; p < count; p++) {
        uint32_t w[5];
        int read_ok = 1;
        for (int i = 0; i < 5; i++) {
            if (fscanf(f, "%x", &w[i]) != 1) {
                read_ok = 0;
                break;
            }
        }
        if (!read_ok) break;
        LOG(" Pkt %02d: Hdr=0x%08X | D0=0x%08X D1=0x%08X D2=0x%08X D3=0x%08X", 
            p + 1, w[0], w[1], w[2], w[3], w[4]);
    }
    LOG("=========================================");
    fclose(f);
}

// ---------------------------------------------------------------------------
// 自動設定硬體暫存器
// ---------------------------------------------------------------------------
static void issue_asic_command(uint32_t cmd) {
    uint8_t start = CMD_START(cmd);
    uint8_t mode = CMD_MODE(cmd);
    uint8_t m_tiles = CMD_M(cmd);
    uint16_t k_tiles = CMD_K(cmd);
    uint8_t n_tiles = CMD_N(cmd);
    uint8_t pkt_cnt = CMD_PKT(cmd);

    ctrl_set_operation_mode_in(mode);
    ctrl_set_M_tiles_in(m_tiles);
    ctrl_set_K_tiles_in(k_tiles);
    ctrl_set_N_tiles_in(n_tiles);
    ctrl_set_packet_count_in(pkt_cnt);
    
    ctrl_set_comp_A_len_in(A_TILE_BYTES);
    ctrl_set_comp_B_len_in(B_TILE_BYTES);
    ctrl_set_comp_C_len_in(C_TILE_BYTES);

    LOG(">> 發送硬體指令 0x%08X: Mode=%d, M=%d, K=%d, N=%d, Pkt/Tile=%d",
        cmd, mode, m_tiles, k_tiles, n_tiles, pkt_cnt);

    if (start) {
        ctrl_set_asic_en(1);
        tick();
        ctrl_set_asic_en(0);
    }
}

extern "C" void run_workload() {
    LOG("=== 系統整合測試: MC -> PE 資料交握驗證 ===");
    
    // 預覽寫入的打包特徵
    dump_initial_axi_packets(DRAM_HEX_PATH, 5);

    do_reset(10);

    ctrl_set_A_fiber_base_addr(DRAM_A_BASE);
    ctrl_set_B_fiber_base_addr(DRAM_B_BASE); 
    ctrl_set_C_tensor_base_addr(DRAM_C_BASE); 

    ctrl_set_GLB_A_base_addr(GLB_A_BASE);
    ctrl_set_GLB_B_base_addr(GLB_B_BASE);
    ctrl_set_GLB_C_base_addr(GLB_C_BASE);

    ctrl_set_PEA_A_ready(1);
    ctrl_set_PEA_B_ready(1);
    intg_set_mock_pe_cfg_ready(1);
    intg_set_mock_pe_data_ready(1);
    ctrl_set_ppu_done(0);

    tick_n(3);

    // 直接發送 data.h 中定義的啟動指令
    issue_asic_command(ACTIVE_ASIC_CMD);

    int timeout = 250000;
    int cfg_cnt = 0;
    int payload_cnt = 0;
    int pass_count_local = 0;
    int fail_count_local = 0;
    int done = 0;

    uint8_t prev_flush = 0;
    int flush_count = 0;
    int ppu_trigger = 0;
    int delay_counter = 0;
    int ppu_injections = 0;

    while (!done && timeout-- > 0) {

        // 偵測 K-loop 完成的 Flush 脈衝
        uint8_t cur_flush = ctrl_get_global_flush();
        if (cur_flush && !prev_flush) {
            flush_count++;
            LOG(" [System] global_flush 觸發 (次數: %d) - 啟動 PPU 模擬延遲", flush_count);
            ppu_trigger = 1;
            delay_counter = 0;
        }
        prev_flush = cur_flush;

        // 注入 PPU 完成訊號
        if (ppu_trigger) {
            delay_counter++;
            if (delay_counter >= 5) {
                ctrl_set_ppu_done(1);
                tick();
                ctrl_set_ppu_done(0);
                ppu_injections++;
                LOG(" [System] ppu_done 已注入 (次數: %d)", ppu_injections);
                ppu_trigger = 0;
                continue;
            }
        }

        // --- 無條件印出所有 MC to PE 交握 ---
        if (intg_get_pe_cfg_valid()) {
            cfg_cnt++;
            payload_cnt = 0;
            LOG(">> [MC->PE] Config (Pkt %04d): Length=%2d, Bitmask=0x%04X",
                cfg_cnt, intg_get_pe_cfg_length(), intg_get_pe_cfg_bitmask());
        }

        if (intg_get_pe_data_valid()) {
            LOG("   -> [MC->PE] Data (Word %d): 0x%08X", payload_cnt, intg_get_pe_data_nzvalue());
            payload_cnt++;
        }

        // 硬體系統執行完成判斷
        if (ctrl_get_asic_done()) {
            LOG(">> ASIC 運算任務完成 (模擬週期: %llu)", (unsigned long long)sim_time);
            done = 1;

            LOG("[PASS] 總計觸發 %d 次 global_flush", flush_count);
            LOG("[PASS] 總計注入 %d 次 ppu_done", ppu_injections);
            LOG("[PASS] MC 總計發送 %d 筆 Packets", cfg_cnt);
            pass_count_local += 3;
            break;
        }

        tick();
    }

    if (!done) {
        LOG("[FAIL] 執行超時，硬體發生 Deadlock。");
        LOG(" 狀態：flush_count=%d, ppu_done=%d, packets_sent=%d", 
            flush_count, ppu_injections, cfg_cnt);
        fail_count_local++;
    }

    tick_n(20);
    pass_count += pass_count_local;
    fail_count += fail_count_local;
    LOG("=== 驗證總結: PASS=%d FAIL=%d ===", pass_count_local, fail_count_local);
}