// =============================================================================
// workload.c — High-Precision Tracking for Input Stationary (IS) Dataflow
// 
// This testbench harness monitors the Matrix Controller (MC) state machine.
// It verifies the core IS property:
// 1. IFMAP (A) is loaded and held stationary in GLB during N-dimension loop.
// 2. Filter (B) is streamed (slid) through GLB for each N-step.
// =============================================================================

#include "tb.h"
#include "data.h"
#include <stdint.h>
#include <stdio.h>

// Display memory map boundaries to verify data placement
static void preview_dram_boundaries(void) {
    LOG("---------------------------------------------------------");
    LOG("[PREVIEW] Memory Map Configuration:");
    LOG("  IFMAP (A)  Base @ 0x%08X", DRAM_A_BASE);
    LOG("  Filter (B) Base @ 0x%08X", DRAM_B_BASE);
    LOG("---------------------------------------------------------");
}

// Issue the 32-bit ASIC command to start the hardware FSM
static void issue_asic_command(uint32_t cmd) {
    ctrl_set_comp_A_len_in(A_TILE_BYTES);
    ctrl_set_comp_B_len_in(B_TILE_BYTES);
    ctrl_set_comp_C_len_in(C_TILE_BYTES);

    ctrl_set_asic_cmd_in(cmd);

    LOG(">> [Host] Issuing ASIC Command: 0x%08X (M=%d, K=%d, N=%d)",
        cmd, CMD_M(cmd), CMD_K(cmd), CMD_N(cmd));

    if (CMD_START(cmd)) {
        ctrl_set_asic_en(1);
        tick();
        ctrl_set_asic_en(0);
    }
}

// [Iris] dump 讀出:flush 後等 PE 算完(pe_compute_done),逐欄掃 dump_addr 抽 16 row 的 psum。
// 此時 controller 停在 S10_WAIT_PPU(等 ppu_done),不會有 acc,dump 與 acc 不衝突。
static void dump_pe_psum(int m_tile, uint32_t total_n) {
    int ncols = (int)total_n * 16;     // N_TILE_SIZE = 16
    int g = 0, nz = 0;
    while (!intg_get_pe_compute_done() && g < 5000) { tick(); g++; }
    if (!intg_get_pe_compute_done())
        LOG("   [DUMP] WARN: pe_compute_done not seen for M-tile %d", m_tile);
    for (int col = 0; col < ncols; col++) {
        intg_set_dump_en(1);
        intg_set_dump_addr((uint32_t)col);
        tick();
        intg_set_dump_en(0);
        // c_valid 只高 1 拍(local_buffer dump 延遲約 2 拍)→ 輪詢抓它高的那拍才讀
        int gv = 0;
        while (!intg_get_c_valid() && gv < 8) { tick(); gv++; }
        if (intg_get_c_valid()) {
            for (int row = 0; row < 16; row++) {
                int32_t v = intg_get_c_out(row);
                if (v != 0) {
                    LOG("   [DUMP] M-tile %d col %2d row %2d : psum=%d", m_tile, col, row, v);
                    nz++;
                }
            }
        }
    }
    LOG("   [DUMP] M-tile %d: %d non-zero psum read out", m_tile, nz);
}

extern "C" void run_workload() {
    LOG("=== DLA INTEGRATION TEST: INPUT STATIONARY DATAFLOW TRACKER ===");
    
    do_reset(10);

    // Initialize MMIO register space
    ctrl_set_A_fiber_base_addr(DRAM_A_BASE);
    ctrl_set_B_fiber_base_addr(DRAM_B_BASE); 
    ctrl_set_C_tensor_base_addr(DRAM_C_BASE); 

    ctrl_set_GLB_A_base_addr(GLB_A_BASE);
    ctrl_set_GLB_B_base_addr(GLB_B_BASE);
    ctrl_set_GLB_C_base_addr(GLB_C_BASE);

    // Set mock hardware handshake signals
    ctrl_set_PEA_A_ready(1);
    ctrl_set_PEA_B_ready(1);
    intg_set_mock_pe_cfg_ready(1);
    intg_set_mock_pe_data_ready(1);
    ctrl_set_ppu_done(0);

    preview_dram_boundaries();
    tick_n(3);

    uint32_t cmd = ACTIVE_ASIC_CMD;
    issue_asic_command(cmd);

    int timeout = 250000;
    int done = 0;

    // Loop boundary thresholds from the 32-bit command
    uint32_t total_m = CMD_M(cmd);
    uint32_t total_k = CMD_K(cmd);
    uint32_t total_n = CMD_N(cmd);

    // Hardware loop tracking variables
    int cur_m = 0, cur_k = 0, cur_n = 0;
    int packet_in_tile = 0;
    
    // Latch configuration header for data-stream correlation
    int wait_for_data = 0;
    uint16_t latched_mask = 0;
    uint16_t latched_len = 0;
    int latched_is_b = 0;   // [Iris 新增] 此封包是 A(0) / B(1),取自 header bit15

    uint32_t total_packets = 0;
    uint8_t prev_flush = 0;
    int flush_count = 0;
    int ppu_delay = 0;

    LOG("[TRACE] Simulation running. Monitoring GLB -> PE interface.");

    while (!done && timeout-- > 0) {

        // 1. Capture Config Header
        // [Iris 修改] 一次 dispatch = A 段(CMD_PKT 包)+ B 段(CMD_PKT 包)= 2*CMD_PKT。
        //            在 A 段首包(packet_in_tile==0)與 B 段首包(==CMD_PKT)各抓一次來印。
        if (intg_get_pe_cfg_valid()) {
            total_packets++;

            if (packet_in_tile == 0 || packet_in_tile == (int)CMD_PKT(cmd)) {
                // A 段首包(且該 K 的第一個 N)才印 IFMAP A LOCKED
                if (packet_in_tile == 0 && cur_n == 0) {
                    LOG("=========================================================");
                    LOG(">> [SRAM_CTRL] IFMAP A (M=%d, K=%d) LOCKED in GLB.", cur_m, cur_k);
                }

                latched_is_b = (intg_get_pe_cfg_length() >> 15) & 0x1; // [Iris 新增] header bit15 = A/B
                latched_len  = intg_get_pe_cfg_length() & 0x1F;        // [Iris 修改] 遮掉 tag,只留長度
                latched_mask = intg_get_pe_cfg_bitmask();
                wait_for_data = 1;
            }
            packet_in_tile++;
        }

        // 2. Capture Data Payload (PE Input)
        if (intg_get_pe_data_valid() && wait_for_data) {
            // [Iris 修改] 依 header tag 標 A / B(原本固定印 "Filter B")
            LOG("   -> [PE_INPUT] Stream %s (N=%02d) | Len:%2d, Mask:0x%04X, Value:0x%08X",
                latched_is_b ? "Filter B" : "IFMAP A ",
                cur_n, latched_len, latched_mask, intg_get_pe_data_nzvalue());
            wait_for_data = 0;
        }

        // 3. Tile Index Advancement (Hardware-Mirror Logic)
        // [Iris 修改] 一次 dispatch = A 段 + B 段 = 2*CMD_PKT 包,送完才前進 N
        if (packet_in_tile == 2 * (int)CMD_PKT(cmd)) {
            packet_in_tile = 0;
            cur_n++; // Move N-index
            if (cur_n >= (int)total_n) {
                cur_n = 0;
                cur_k++; // Move K-index
                if (cur_k >= (int)total_k) {
                    cur_k = 0;
                    cur_m++; // Move M-index
                }
            }
        }

        // 4. Handle Global Flush (End of K-dimension convolution)
        uint8_t cur_flush = ctrl_get_global_flush();
        if (cur_flush && !prev_flush) {
            flush_count++;
            // [Iris 修改] cur_m 在該 M 最後一個 dispatch 完成時已 +1,flush 屬於剛結束的 M → 印 cur_m-1
            LOG(">> [FLUSH] K-loop exhausted for M=%d. Redirecting Partial Sums to PPU.", cur_m - 1);
            dump_pe_psum(cur_m - 1, total_n);   // [Iris] 把該 M-tile 的 PE psum 抽出來看
            ppu_delay = 1;
        }
        prev_flush = cur_flush;

        // 5. Simulate PPU Quantization/ReLU Latency
        if (ppu_delay > 0) {
            ppu_delay++;
            if (ppu_delay >= 5) {
                ctrl_set_ppu_done(1);
                tick();
                ctrl_set_ppu_done(0);
                LOG("   [PPU->DMA] Quantization completed. Triggered Writeback.");
                ppu_delay = 0;
            }
        }

        // 6. ASIC Completion Check
        if (ctrl_get_asic_done()) {
            // [Iris 修改] A+B 兩段 → 每個 (M,K,N) dispatch 送 2*CMD_PKT 包
            uint32_t expected_packets = total_m * total_k * total_n * 2 * CMD_PKT(cmd);
            LOG("---------------------------------------------------------");
            LOG("  Status                       : SUCCESS");
            LOG("  Total Execution Cycles       : %llu", (unsigned long long)sim_time);
            LOG("  Packets Dispatched to Array  : %u / %u", total_packets, expected_packets);
            LOG("  Total Flush Pulses Processed : %d / %d", flush_count, total_m);
            LOG("========================================================");
            done = 1;
            break;
        }

        tick();
    }

    if (!done) {
        LOG("[FATAL] Deadlock detected. Hardware FSM stalled.");
        fail_count++;
    }

    tick_n(20);
}
