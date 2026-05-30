// driver_dla.cpp — DLA register-level driver.
//
// The DlaHAL instance is owned by tb.cpp. tb.cpp calls set_dla_hal(&hal) once
// after construction so that all register-level helpers below can reach the
// same HAL object.

#include "driver_dla.h"

#include <assert.h>
#include <stdio.h>

#include "dla_hal.hpp"

static DlaHAL* g_hal = nullptr;

void set_dla_hal(DlaHAL* hal) { g_hal = hal; }
DlaHAL* get_dla_hal() { return g_hal; }

void reg_write(uint32_t offset, uint32_t value) {
    assert(g_hal != nullptr);
    g_hal->memory_set(offset + DLA_MMIO_BASE_ADDR, value);
}

/* DLA configuration */
void set_enable(uint32_t scale_factor, bool maxpool, bool relu,
                bool operation) {
    uint32_t value;

    // [TODO]: Pack the enable register with scale factor, operation mode,
    //         and activation function flags into the appropriate bitfields.
    /*! <<<========= Implement here =========>>> */
    value = (scale_factor << 4) | (operation << 3) | (relu << 2) | (maxpool << 1) | 1;

    reg_write(DLA_ENABLE_OFFSET, value);
}

void set_mapping_param(uint32_t m, uint32_t e, uint32_t p, uint32_t q,
                       uint32_t r, uint32_t t) {
    // [TODO]: Pack the mapping parameters (m, e, p, q, r, t) into their
    //         respective bitfield positions in the mapping config register.
    /*! <<<========= Implement here =========>>> */
    uint32_t value = (m << 16) | (e << 12) | (p << 9) | (q << 6) | (r << 3) | t;
    reg_write(DLA_MAPPING_PARAM_OFFSET, value);
}

void set_shape_param1(uint32_t PAD, uint32_t U, uint32_t R, uint32_t S,
                      uint32_t C, uint32_t M) {
    // [TODO]: Pack the shape parameters (PAD, U, R, S, C, M) into their
    //         respective bitfield positions in the shape config register.
    /*! <<<========= Implement here =========>>> */
    uint32_t value = (PAD << 26) | (U << 24) | (R << 22) | (S << 20) | (C << 10) | M;
    reg_write(DLA_SHAPE_PARAM1_OFFSET, value);
}

void set_shape_param2(uint32_t W, uint32_t H, uint32_t PAD) {
    // [TODO]: Calculate and pack the padded width and padded height into
    //         the shape config register bitfields.
    /*! <<<========= Implement here =========>>> */
    uint32_t padded_W = W + 2 * PAD;
    uint32_t padded_H = H + 2 * PAD;
    uint32_t value = (padded_W << 8) | padded_H;
    reg_write(DLA_SHAPE_PARAM2_OFFSET, value);

    // uint32_t value = ((W & 0xFF) << 8) | (H & 0xFF); 
    // reg_write(DLA_SHAPE_PARAM2_OFFSET, value);

    // uint32_t value = (W << 8) | H; 
    // reg_write(DLA_SHAPE_PARAM2_OFFSET, value);
}

void set_ifmap_addr(uint8_t* addr) {
    reg_write(DLA_IFMAP_ADDR_OFFSET, (uint32_t)(uintptr_t)addr);
}

void set_filter_addr(int8_t* addr) {
    reg_write(DLA_FILTER_ADDR_OFFSET, (uint32_t)(uintptr_t)addr);
}

void set_bias_addr(int32_t* addr) {
    reg_write(DLA_BIAS_ADDR_OFFSET, (uint32_t)(uintptr_t)addr);
}

void set_opsum_addr(uint8_t* addr) {
    reg_write(DLA_OPSUM_ADDR_OFFSET, (uint32_t)(uintptr_t)addr);
}

void set_glb_filter_addr(uint32_t addr) {
    reg_write(DLA_GLB_FILTER_ADDR_OFFSET, addr);
}

void set_glb_bias_addr(uint32_t addr) {
    reg_write(DLA_GLB_BIAS_ADDR_OFFSET, addr);
}

void set_glb_ofmap_addr(uint32_t addr) {
    reg_write(DLA_GLB_OFMAP_ADDR_OFFSET, addr);
}

void set_input_activation_len(uint32_t len) {
    reg_write(DLA_IFMAP_LEN_OFFSET, len);
};

void set_output_activation_len(uint32_t len) {
    reg_write(DLA_OFMAP_LEN_OFFSET, len);
};
