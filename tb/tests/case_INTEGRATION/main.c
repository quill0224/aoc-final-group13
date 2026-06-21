// =============================================================================
// main.c — case_INTEGRATION entry point (Input Stationary Dataflow)
// =============================================================================

#include "tb.h"
#include "data_packer.h"
#include "data.h"

#ifdef __cplusplus
extern "C" {
#endif
    void run_workload();
#ifdef __cplusplus
}
#endif

int main(int argc, char** argv) {

    // 1. 自動從 data.h 的指令中解析出 M 與 K 的維度
    uint32_t active_m = CMD_M(ACTIVE_ASIC_CMD);
    uint32_t active_k = CMD_K(ACTIVE_ASIC_CMD);

    // 2. 自動計算所需的封包數量 (M * K * 每個Tile的封包數16)
    uint32_t required_packets = (active_m * active_k * 16) + 256;
    if (required_packets > 13000) {
        required_packets = 13000;
    }

    // 3. 雙通道資料打包 (Data Packing for A and B)
    // 打包矩陣 A (IFMAP) -> 對應 DRAM_A_BASE (0x00000000)
    uint32_t bytes_a = DataPacker::compress_to_hex(
        MASK_PATH_A, 
        VAL_PATH_A, 
        DRAM_HEX_PATH_A,
        0,                 // word_base_addr = 0
        required_packets
    );

    // 打包矩陣 B (Filter) -> 對應 DRAM_B_BASE (0x00010000 >> 2 = 0x4000 Words)
    uint32_t bytes_b = DataPacker::compress_to_hex(
        MASK_PATH_B, 
        VAL_PATH_B, 
        DRAM_HEX_PATH_B,
        0x4000,            // word_base_addr = 0x00010000 / 4
        required_packets
    );

    tb_init(argc, argv, "trace_INTEGRATION");

    if (bytes_a > 0 && bytes_b > 0) {
        run_workload();
    } else {
        fprintf(stderr, "[ERROR] 測資打包失敗，請確認檔案路徑與 DataPacker 設定。\n");
    }

    tb_close();
    return fail_count == 0 ? 0 : 1;
}
