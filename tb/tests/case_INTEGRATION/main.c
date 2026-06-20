#include "tb.h"
#include "data_packer.h"

#ifdef __cplusplus
extern "C" {
#endif
    void run_workload(uint32_t compressed_bytes);
#ifdef __cplusplus
}
#endif

int main(int argc, char** argv) {
    const char* mask_path = "../../../GEMM/outputs/layer_40_conv/hw_bitmask/input_A_bitmask_64b_hex.txt";
    const char* val_path  = "../../../GEMM/outputs/layer_40_conv/hw_bitmask/input_A_values_hex.txt";
    const char* hex_path  = "dram_test.hex"; 

    uint32_t bytes = DataPacker::compress_to_hex(mask_path, val_path, hex_path, 0);

    tb_init(argc, argv, "trace_INTEGRATION");
    
    if (bytes > 0) {
        run_workload(bytes);
    }
    
    tb_close();
    return fail_count == 0 ? 0 : 1;
}