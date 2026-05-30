#include <stdio.h>
#include <stdlib.h>

#include "driver_dla.h"
#include "runtime.h"

/*  //////////      NOTICE      //////////
    all parameter used to set DLA are send in by function argument
*/

void dla_stop() {
    // set disable
    reg_write(DLA_ENABLE_OFFSET, 0);
}

void create_dla_info_to_csv(const char* filename) {
    fprintf(stdout, "Creating dla info file: %s\n", filename);
    FILE* file = fopen(filename, "w");
    if (!file) {
        fprintf(stderr, "Create DLA info file failed.\n");
        return;
    }
    fprintf(file,
            "Operation,Cycles,Time(ns),Memory read,Memory "
            "write,m,e,p,q,r,t,PAD,U,R,S,C,M,W,H\n");
    fclose(file);
}

void dump_dla_info_to_csv(const char* filename, const char* operation_name,
                          // mapping parameter
                          uint32_t m, uint32_t e, uint32_t p, uint32_t q,
                          uint32_t r, uint32_t t,
                          // shape parameter
                          uint32_t PAD, uint32_t U, uint32_t R, uint32_t S,
                          uint32_t C, uint32_t M, uint32_t W, uint32_t H) {
    FILE* file = fopen(filename, "a");
    struct runtime_info info = get_dla_hal()->get_runtime_info();
    fprintf(file, "%s,", operation_name);  // Operation
    fprintf(file, "%10llu,", (unsigned long long)info.elapsed_cycle);  // Cycles
    fprintf(file, "%10llu,", (unsigned long long)info.elapsed_time);   // Time (ns)
    fprintf(file, "%10d,", info.memory_read);        // Memory read
    fprintf(file, "%10d,", info.memory_write);       // Memory write
    fprintf(file, "%d,%d,%d,%d,%d,%d,", m, e, p, q, r, t);
    fprintf(file, "%d,%d,%d,%d,%d,%d,%d,%d\n", PAD, U, R, S, C, M, W, H);
    fclose(file);
}

int qconv2d_relu_maxpool(
    uint8_t* input_in_DRAM, int8_t* filter_in_DRAM, uint8_t* opsum_in_DRAM,
    int32_t* bias, uint32_t ofmap_len, uint32_t ifmap_len, uint32_t filter_len,
    // mapping parameter
    uint32_t m, uint32_t e, uint32_t p, uint32_t q, uint32_t r, uint32_t t,
    // shape parameter
    uint32_t PAD, uint32_t U, uint32_t R, uint32_t S, uint32_t C, uint32_t M,
    uint32_t W, uint32_t H,
    uint32_t scale) {  // int32_t scale_factor: merge ifmap and weight and ofmap
    // scale bit-shift

#ifdef DLA_INFO
    get_dla_hal()->reset_runtime_info();
    // dla_reset_runtime_info();
#endif
    // [TODO]: Calculate the sizes and base addresses of each data region
    /*! <<<========= Implement here =========>>> */

    uint32_t align_C = ((C + 3) / 4) * 4; 
    // uint32_t glb_ifmap_size = align_C * W * H; 
    uint32_t glb_ifmap_size = ifmap_len;
    uint32_t best_m = 1;  
    for (uint32_t tm = M; tm > 0; tm--) {
        if (M % tm != 0) continue;
        // uint32_t psum_size   = tm * e * e * 4; 
        uint32_t psum_size   = tm * W * H * 4;
        uint32_t bias_size   = tm * 4;
        uint32_t filter_size = tm * align_C * R * S;
        if ((glb_ifmap_size + bias_size + filter_size + psum_size) <= 65536) {
            best_m = tm;
            break;
        }
    }
    uint32_t m_tile = best_m;

    uint32_t glb_filter_addr = glb_ifmap_size;
    uint32_t glb_bias_addr   = glb_filter_addr + (m_tile * align_C * R * S);
    uint32_t glb_opsum_addr  = glb_bias_addr + (m_tile * 4);

    // [TODO]: Configure all DLA hardware registers
    /*! <<<========= Implement here =========>>> */
    reg_write(DLA_IFMAP_ADDR_OFFSET, (uint32_t)(uintptr_t)input_in_DRAM);
    reg_write(DLA_FILTER_ADDR_OFFSET, (uint32_t)(uintptr_t)filter_in_DRAM);
    reg_write(DLA_BIAS_ADDR_OFFSET, (uint32_t)(uintptr_t)bias);
    reg_write(DLA_OPSUM_ADDR_OFFSET, (uint32_t)(uintptr_t)opsum_in_DRAM);
    
    reg_write(DLA_GLB_BIAS_ADDR_OFFSET, glb_bias_addr);
    reg_write(DLA_GLB_FILTER_ADDR_OFFSET, glb_filter_addr);
    reg_write(DLA_GLB_OFMAP_ADDR_OFFSET, glb_opsum_addr);
    
    reg_write(DLA_IFMAP_LEN_OFFSET, ifmap_len);
    reg_write(DLA_OFMAP_LEN_OFFSET, ofmap_len);

    set_mapping_param(m_tile, e, p, q, r, t);
    set_shape_param1(PAD, U, R, S, C, M);
    set_shape_param2(W, H, PAD); 
    
    set_enable(scale, 1, 1, 0);

    get_dla_hal()->wait_for_irq();
    dla_stop();
#ifdef DLA_INFO
    dump_dla_info_to_csv(DLA_INFO_CSV, "qconv2d_relu_maxpool", m_tile, e, p, q, r, t,
                         PAD, U, R, S, C, M, W, H);
#endif
    return 0;
};

int qconv2d_relu(uint8_t* input_in_DRAM, int8_t* filter_in_DRAM,
                 uint8_t* opsum_in_DRAM, int32_t* bias, uint32_t ofmap_len,
                 uint32_t ifmap_len, uint32_t filter_len,
                 // mapping parameter
                 uint32_t m, uint32_t e, uint32_t p, uint32_t q, uint32_t r,
                 uint32_t t,
                 // shape parameter
                 uint32_t PAD, uint32_t U, uint32_t R, uint32_t S, uint32_t C,
                 uint32_t M, uint32_t W, uint32_t H,
                 uint32_t scale) {  // int32_t scale_factor: merge ifmap and
                                    // ofmap scale bit-shift
#ifdef DLA_INFO
    // dla_reset_runtime_info();
    get_dla_hal()->reset_runtime_info();
#endif
    // [TODO]: Calculate the sizes and base addresses of each data region
    /*! <<<========= Implement here =========>>> */

    uint32_t align_C = ((C + 3) / 4) * 4; 
    uint32_t glb_ifmap_size = align_C * W * H; 
    // uint32_t glb_ifmap_size = ifmap_len;
    uint32_t best_m = 1;  
    for (uint32_t tm = M; tm > 0; tm--) {
        if (M % tm != 0) continue;
        uint32_t psum_size   = tm * e * e * 4; 
        // uint32_t psum_size   = tm * W * H * 4;
        uint32_t bias_size   = tm * 4;
        uint32_t filter_size = tm * align_C * R * S;
        if ((glb_ifmap_size + bias_size + filter_size + psum_size) <= 65536) {
            best_m = tm;
            break;
        }
    }
    uint32_t m_tile = best_m;

    uint32_t glb_filter_addr = glb_ifmap_size;
    uint32_t glb_bias_addr   = glb_filter_addr + (m_tile * align_C * R * S);
    uint32_t glb_opsum_addr  = glb_bias_addr + (m_tile * 4);

    // [TODO]: Configure all DLA hardware registers
    /*! <<<========= Implement here =========>>> */
    reg_write(DLA_IFMAP_ADDR_OFFSET, (uint32_t)(uintptr_t)input_in_DRAM);
    reg_write(DLA_FILTER_ADDR_OFFSET, (uint32_t)(uintptr_t)filter_in_DRAM);
    reg_write(DLA_BIAS_ADDR_OFFSET, (uint32_t)(uintptr_t)bias);
    reg_write(DLA_OPSUM_ADDR_OFFSET, (uint32_t)(uintptr_t)opsum_in_DRAM);
    
    reg_write(DLA_GLB_BIAS_ADDR_OFFSET, glb_bias_addr);
    reg_write(DLA_GLB_FILTER_ADDR_OFFSET, glb_filter_addr);
    reg_write(DLA_GLB_OFMAP_ADDR_OFFSET, glb_opsum_addr);
    
    reg_write(DLA_IFMAP_LEN_OFFSET, ifmap_len);
    reg_write(DLA_OFMAP_LEN_OFFSET, ofmap_len);

    set_mapping_param(m_tile, e, p, q, r, t);
    set_shape_param1(PAD, U, R, S, C, M);
    set_shape_param2(W, H, PAD); 
    
    set_enable(scale, 0, 1, 0);

    get_dla_hal()->wait_for_irq();
    dla_stop();
#ifdef DLA_INFO
    dump_dla_info_to_csv(DLA_INFO_CSV, "qconv2d_relu", m_tile, e, p, q, r, t, PAD, U,
                         R, S, C, M, W, H);
#endif
    return 0;
};