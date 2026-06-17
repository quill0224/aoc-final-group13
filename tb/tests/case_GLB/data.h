#pragma once
#include <stdint.h>

#define GLB_TC01_WORDS 8
#define GLB_TC02_ADDR  0x00000010
#define GLB_TC03_ADDR_LO 0x00000000
#define GLB_TC03_ADDR_HI 0x0000007F // 假設 128 words 深度

// TC01: 基礎讀寫測試資料
static const uint32_t tc01_data[GLB_TC01_WORDS] = {
    0x11111111, 0x22222222, 0x33333333, 0x44444444,
    0x55555555, 0x66666666, 0x77777777, 0x88888888
};

// TC02: WSTRB Byte Enable 測試資料
static const uint32_t tc02_full_val    = 0xFFFFFFFF; // 初始全 1
static const uint32_t tc02_partial_val = 0x12345678; // 欲寫入的資料
static const uint8_t  tc02_wstrb_mask  = 0x03;       // 0b0011 (只寫入 lower 2 bytes)
static const uint32_t tc02_expected    = 0xFFFF5678; // 預期結果 (上層保留，下層覆寫)

// TC03: 邊界位址測試資料
static const uint32_t tc03_data[2] = {
    0xDEADBEEF, 0xCAFEBABE
};
