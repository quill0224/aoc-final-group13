#pragma once
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// =============================================================================
// DataPacker
//
// 把 hw_bitmask 的兩個檔案打包成 $readmemh 相容的 hex 檔
//
// 輸入 bitmask 格式：每行一個 64-bit hex
// 切成 4 個 16-bit chunk：
// chunk 0 = bits[15:0] → packet 0
// chunk 1 = bits[31:16] → packet 1
// chunk 2 = bits[47:32] → packet 2
// chunk 3 = bits[63:48] → packet 3
//
// 輸出 packet 格式（160-bit = 20 bytes = 5 words）：
// Word 0: {is_b[31], length[30:16], bitmask[15:0]}   // [Iris 新增] bit31=is_b(0=A/1=B)
// Word 1: NZ[0..3] (packed INT8, LSB first)
// Word 2: NZ[4..7]
// Word 3: NZ[8..11]
// Word 4: NZ[12..15]
//
// 參數：
// word_base_addr : hex 檔起始 word 地址（@XXXX header）
// max_packets : 0 = 不限；>0 = 只輸出前 N 個 packet
// 1 tile = 16 packets（= 4 行 64-bit bitmask）
// =============================================================================

class DataPacker {
public:

static uint32_t compress_to_hex(
const char* mask_path,
const char* val_path,
const char* hex_path,
uint32_t word_base_addr,
uint32_t max_packets = 0, // 0 = 不限
int is_b = 0             // [Iris 新增] 0=A(IFMAP)/1=B(Filter):寫進 Word0 bit31 當 A/B tag
) {
FILE* f_mask = fopen(mask_path, "r");
FILE* f_val = fopen(val_path, "r");
FILE* fout = fopen(hex_path, "w");

if (!f_mask || !f_val || !fout) {
fprintf(stderr,
"[DataPacker] ERROR: cannot open files\n"
" mask: %s\n val: %s\n out: %s\n",
mask_path, val_path, hex_path);
if (f_mask) fclose(f_mask);
if (f_val) fclose(f_val);
if (fout) fclose(fout);
return 0;
}

fprintf(fout, "@%X\n", word_base_addr);

char mask_str[64];
uint32_t unsigned_val;
uint32_t total_bytes = 0;
uint32_t packet_count = 0;
int done = 0;

while (!done && fscanf(f_mask, "%63s", mask_str) == 1) {

unsigned long long mask64 = strtoull(mask_str, NULL, 16);

for (int c = 0; c < 4 && !done; c++) {

if (max_packets > 0 && packet_count >= max_packets) {
done = 1;
break;
}

uint16_t mask16 = (uint16_t)((mask64 >> (c * 16)) & 0xFFFFULL);

uint8_t nz[16] = {0};
uint16_t length = 0;

for (int b = 0; b < 16; b++) {
if (mask16 & (1u << b)) {
if (fscanf(f_val, "%x", &unsigned_val) == 1) {
nz[length++] = (uint8_t)unsigned_val;
} else {
fprintf(stderr,
"[DataPacker] WARNING: ran out of NZ values "
"at packet %u\n", packet_count);
done = 1;
break;
}
}
}

// Word 0: {is_b[31], length, bitmask}   // [Iris 修改] is_b 寫進 bit31
fprintf(fout, "%08X\n",
(((uint32_t)is_b & 0x1u) << 31) | ((uint32_t)length << 16) | (uint32_t)mask16);

// Word 1~4: NZ values packed
for (int w = 0; w < 4; w++) {
uint32_t payload = 0;
for (int b = 0; b < 4; b++) {
int idx = w * 4 + b;
if (idx < (int)length)
payload |= ((uint32_t)nz[idx] << (b * 8));
}
fprintf(fout, "%08X\n", payload);
}

total_bytes += 20;
packet_count++;
}
}

fclose(f_mask);
fclose(f_val);
fclose(fout);

printf("[DataPacker] %u packets written (%u bytes) → %s\n",
packet_count, total_bytes, hex_path);

return total_bytes;
}
};
