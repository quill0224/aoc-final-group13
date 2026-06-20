#pragma once
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

class DataPacker {
public:
    static uint32_t compress_to_hex(const char* mask_path, const char* val_path, const char* hex_path, uint32_t word_base_addr) {
        
        FILE* f_mask = fopen(mask_path, "r");
        FILE* f_val  = fopen(val_path, "r");
        FILE* fout   = fopen(hex_path, "w");

        if (!f_mask || !f_val || !fout) {
            if (f_mask) fclose(f_mask);
            if (f_val)  fclose(f_val);
            if (fout)   fclose(fout);
            return 0;
        }

        fprintf(fout, "@%X\n", word_base_addr);
        
        char mask_str[64];
        uint32_t val;
        uint32_t total_bytes = 0;
        
        const uint32_t MAX_WORDS = 60000;
        uint32_t words_written = 0;

        while (fscanf(f_mask, "%63s", mask_str) == 1) {
            if (words_written >= MAX_WORDS) break;

            unsigned long long mask64 = strtoull(mask_str, NULL, 16);

            for (int chunk = 0; chunk < 4; chunk++) {
                uint16_t mask16 = (mask64 >> (chunk * 16)) & 0xFFFF;
                uint16_t length = 0;
                uint8_t nz[16] = {0};

                for (int b = 0; b < 16; b++) {
                    if (mask16 & (1 << b)) {
                        if (fscanf(f_val, "%x", &val) == 1) {
                            nz[length++] = (uint8_t)val;
                        } else {
                            fclose(f_mask); fclose(f_val); fclose(fout);
                            return total_bytes;
                        }
                    }
                }

                uint32_t word0 = (length << 16) | mask16;
                fprintf(fout, "%08X\n", word0);
                words_written++;

                for (int w = 0; w < 4; w++) {
                    uint32_t payload = 0;
                    for (int byte_idx = 0; byte_idx < 4; byte_idx++) {
                        int nz_idx = w * 4 + byte_idx;
                        if (nz_idx < length) {
                            payload |= (nz[nz_idx] << (byte_idx * 8));
                        }
                    }
                    fprintf(fout, "%08X\n", payload);
                    words_written++;
                }
                total_bytes += 20; 
                
                if (words_written >= MAX_WORDS) break;
            }
        }
        
        fclose(f_mask);
        fclose(f_val);
        fclose(fout);
        return total_bytes;
    }
};