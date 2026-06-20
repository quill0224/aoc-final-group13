#include "tb.h"
#include "data_packer.h"
#include "data.h"

#ifdef __cplusplus
extern "C" {
#endif
    // 移除 mode 參數，全域由 ACTIVE_ASIC_CMD 驅動
    void run_workload();
#ifdef __cplusplus
}
#endif

int main(int argc, char** argv) {

    // 1. 自動從指令中解析出 M 與 K 的維度
    uint32_t active_m = CMD_M(ACTIVE_ASIC_CMD);
    uint32_t active_k = CMD_K(ACTIVE_ASIC_CMD);

    // 2. 自動計算所需的封包數量 (M * K * 每個Tile的封包數16)
    uint32_t required_packets = (active_m * active_k * 16) + 256;
    if (required_packets > 13000) required_packets = 13000;

    // 3. 嚴格傳入 5 個參數 (對齊你的 data_packer.h)
    uint32_t bytes = DataPacker::compress_to_hex(
        MASK_PATH_A, 
        VAL_PATH_A, 
        DRAM_HEX_PATH,
        0,                 // word_base_addr
        required_packets   // max_packets
    );

    tb_init(argc, argv, "trace_INTEGRATION");

    if (bytes > 0) {
        run_workload();
    } else {
        fprintf(stderr, "[ERROR] 測資打包失敗，請確認檔案路徑。\n");
    }

    tb_close();
    return fail_count == 0 ? 0 : 1;
}