#include "data_packer.h"

int main() {
    const char* mask_path = "../../../GEMM/outputs/layer_40_conv/hw_bitmask/input_A_bitmask_64b_hex.txt";
    const char* val_path  = "../../../GEMM/outputs/layer_40_conv/hw_bitmask/input_A_values_hex.txt";
    const char* hex_path  = "dram_verify.hex";

    printf("=== Layer 40 DataPacker Verification ===\n");
    uint32_t bytes = DataPacker::compress_to_hex(mask_path, val_path, hex_path, 0x0400, 500, 16);
    printf("========================================\n");
    printf("Total Bytes Packed: %u Bytes\n", bytes);
    
    return 0;
}
