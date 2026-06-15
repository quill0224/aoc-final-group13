#pragma once
#include <cstdint>

// Controller FSM test:
// Minimal 1-tile run: M=1, K=1, N=1
// We stub DMA_done, k_done, ppu_done externally via C++
// and verify state transitions match expected sequence

// MMIO parameters for a 1×1×1 tile run (minimal)
static const uint32_t CTRL_COMP_A_LEN  = 20;        // 1 packet × 20 bytes, 4B-aligned
static const uint32_t CTRL_COMP_B_LEN  = 20;
static const uint32_t CTRL_COMP_C_LEN  = 16;        // 16×1 output bytes (4B-aligned)
static const uint8_t  CTRL_N_TILES     = 1;
static const uint16_t CTRL_K_TILES     = 1;
static const uint8_t  CTRL_M_TILES     = 1;
static const uint8_t  CTRL_PKT_COUNT   = 1;
static const uint8_t  CTRL_OP_MODE     = 0x01;      // TrIP

// DRAM addresses
static const uint32_t CTRL_A_DRAM_BASE = 0x00010000;
static const uint32_t CTRL_B_DRAM_BASE = 0x00020000;
static const uint32_t CTRL_C_DRAM_BASE = 0x00030000;

// GLB addresses (from ASIC.svh)
static const uint16_t CTRL_GLB_A_BASE  = 0x0000;
static const uint16_t CTRL_GLB_B_BASE  = 0x0140;
static const uint16_t CTRL_GLB_C_BASE  = 0x0280;

// PE mapping (e=8, p=1, q=1, r=1, t=1)
static const uint8_t  CTRL_E = 8;
static const uint8_t  CTRL_P = 1;
static const uint8_t  CTRL_Q = 1; // q[2] must be 0
static const uint8_t  CTRL_R = 1;
static const uint8_t  CTRL_T = 1;

// Expected FSM state sequence (4-bit encoding from top_controller.sv):
// S0(0)→S1(1)→S2(2)→S3(3)→S4(4)→S5(5)→S6(6)→S7(7)→S8(8)→S9(9)→S10(10)→S9b(11)→S11(12)→S0(0)
static const int CTRL_EXPECTED_STATE_SEQ_LEN = 14;
static const uint8_t ctrl_expected_states[14] = {
    0,   // S0_IDLE (initial)
    1,   // S1_SHADOW_LATCH
    2,   // S2_DMA_FETCH_A
    3,   // S3_DMA_FETCH_B
    4,   // S4_SEND_PE_CONFIG
    5,   // S5_MC_DISPATCH
    6,   // S6_WAIT_K_DONE
    7,   // S7_FLUSH
    8,   // S8_WAIT_PPU
    9,   // S9_UPDATE_NK
    10,  // S10_DMA_WRITEBACK
    11,  // S9b_UPDATE_M
    12,  // S11_DONE
    0    // back to S0_IDLE
};

// Human-readable state names for logging
static const char* CTRL_STATE_NAMES[13] = {
    "S0_IDLE",
    "S1_SHADOW_LATCH",
    "S2_DMA_FETCH_A",
    "S3_DMA_FETCH_B",
    "S4_SEND_PE_CONFIG",
    "S5_MC_DISPATCH",
    "S6_WAIT_K_DONE",
    "S7_FLUSH",
    "S8_WAIT_PPU",
    "S9_UPDATE_NK",
    "S10_DMA_WRITEBACK",
    "S9b_UPDATE_M",
    "S11_DONE"
};