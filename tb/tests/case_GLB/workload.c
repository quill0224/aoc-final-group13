// =============================================================================
// case_GLB/workload.c — Global Buffer Unit Test Workload
//
// Test cases:
// TC01 Normal write then read (8 words)
// TC02 WSTRB partial mask (Byte Enable 測試)
// TC03 Address boundary (addr 0 and max)
// =============================================================================

#include "workload.h"
#include "data.h"
#include "tb.h"

// ------------------------------------------------------------------
// Helper: 寫入 32-bit 資料至 GLB
// 假設 EN=1 啟動, WEB=0 寫入, WSTRB 控制 byte (1 為有效)
// ------------------------------------------------------------------
static void glb_write(uint32_t addr, uint32_t data, uint8_t wstrb) {
    glb_set_A(addr);
    glb_set_DI(data);
    glb_set_WSTRB(wstrb);
    glb_set_EN(1);
    glb_set_WEB(0);
    tick(); // 觸發正緣寫入
    glb_set_EN(0);  // 關閉致能避免誤動作
    glb_set_WEB(1);
}

// ------------------------------------------------------------------
// Helper: 從 GLB 讀取 32-bit 資料
// 假設 EN=1 啟動, WEB=1 讀取，並具有 1 cycle 讀取延遲
// ------------------------------------------------------------------
static uint32_t glb_read(uint32_t addr) {
    glb_set_A(addr);
    glb_set_EN(1);
    glb_set_WEB(1);
    tick(); // 正緣送出位址與讀取控制訊號
    glb_set_EN(0); 
    tick(); // 等待 1 cycle 讀取延遲 (若硬體為 0 cycle 則移除此行)
    return glb_get_DO();
}

// ------------------------------------------------------------------
// TC01 — 基礎循序寫入與讀取
// ------------------------------------------------------------------
static void tc01_normal_write_read(void) {
    LOG("--- TC01: Normal Write/Read (%d words) ---", GLB_TC01_WORDS);

    // 寫入階段 (全開 Byte Enable: 0b1111 = 0x0F)
    for (int i = 0; i < GLB_TC01_WORDS; i++) {
        // 注意這裡：位址必須每次 +4 來對齊 32-bit (4 Bytes)
        uint32_t addr = (uint32_t)(i * 4);
        glb_write(addr, tc01_data[i], 0x0F); 
    }

    tick_n(2); // 狀態切換閒置

    // 讀取比對階段
    for (int i = 0; i < GLB_TC01_WORDS; i++) {
        uint32_t addr = (uint32_t)(i * 4);
        uint32_t got = glb_read(addr);
        CHECK(got == tc01_data[i],
              "TC01 addr=0x%08X exp=0x%08X got=0x%08X",
              addr, tc01_data[i], got);
    }
}

// ------------------------------------------------------------------
// TC02 — WSTRB 部分位元組寫入 (Byte Enable)
// ------------------------------------------------------------------
static void tc02_wstrb_partial_mask(void) {
    LOG("--- TC02: WSTRB Partial Mask ---");

    // 步驟 1: 寫入全 1 作為背景 (WSTRB = 0x0F)
    glb_write(GLB_TC02_ADDR, tc02_full_val, 0x0F);
    tick_n(2);

    // 步驟 2: 僅覆寫 Lower 2 Bytes (WSTRB = 0x03)
    glb_write(GLB_TC02_ADDR, tc02_partial_val, tc02_wstrb_mask);
    tick_n(2);

    // 步驟 3: 讀出並驗證 (預期 Upper 2 Bytes 維持 FF，Lower 2 Bytes 被覆寫)
    uint32_t got = glb_read(GLB_TC02_ADDR);
    CHECK(got == tc02_expected,
          "TC02 exp=0x%08X got=0x%08X",
          tc02_expected, got);
}

// ------------------------------------------------------------------
// TC03 — 位址邊界測試
// ------------------------------------------------------------------
static void tc03_address_boundary(void) {
    LOG("--- TC03: Address Boundary (0 and Max) ---");

    glb_write(GLB_TC03_ADDR_LO, tc03_data[0], 0x0F);
    glb_write(GLB_TC03_ADDR_HI, tc03_data[1], 0x0F);
    tick_n(2);

    uint32_t got_lo = glb_read(GLB_TC03_ADDR_LO);
    uint32_t got_hi = glb_read(GLB_TC03_ADDR_HI);

    CHECK(got_lo == tc03_data[0],
          "TC03 addr=0x%08X exp=0x%08X got=0x%08X",
          GLB_TC03_ADDR_LO, tc03_data[0], got_lo);
    CHECK(got_hi == tc03_data[1],
          "TC03 addr=0x%08X exp=0x%08X got=0x%08X",
          GLB_TC03_ADDR_HI, tc03_data[1], got_hi);
}

// ------------------------------------------------------------------
// 任務進入點
// ------------------------------------------------------------------
void run_workload(void) {
    LOG("=== GLB Unit Test Start ===");

    do_reset(2); // 觸發硬體 rst 訊號

    tc01_normal_write_read();
    tc02_wstrb_partial_mask();
    tc03_address_boundary();

    LOG("=== GLB Unit Test End ===");
}