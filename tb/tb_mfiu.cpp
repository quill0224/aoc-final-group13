#include "Vmfiu.h"
#include "verilated.h"

#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

namespace {

vluint64_t sim_time = 0;

uint64_t pack_b(uint16_t col0, uint16_t col1, uint16_t col2, uint16_t col3) {
    return (static_cast<uint64_t>(col0) << 0) |
           (static_cast<uint64_t>(col1) << 16) |
           (static_cast<uint64_t>(col2) << 32) |
           (static_cast<uint64_t>(col3) << 48);
}

void eval(Vmfiu* dut) {
    dut->eval();
}

void tick(Vmfiu* dut) {
    dut->clk = 0;
    eval(dut);
    ++sim_time;
    dut->clk = 1;
    eval(dut);
    ++sim_time;
    dut->clk = 0;
    eval(dut);
    ++sim_time;
}

void set_idle_inputs(Vmfiu* dut) {
    dut->en = 0;
    dut->mode = 0;
    dut->a_in_valid = 0;
    dut->b_in_valid = 0;
    dut->a_last = 0;
    dut->b_group_last = 0;
    dut->a_bitmask = 0;
    dut->b_bitmask = 0;
    dut->b_col_valid = 0;
}

void reset(Vmfiu* dut) {
    set_idle_inputs(dut);
    dut->rst_n = 0;
    tick(dut);
    tick(dut);
    dut->rst_n = 1;
    tick(dut);
}

uint8_t get_a_lane(const Vmfiu* dut, int lane) {
    return static_cast<uint8_t>((dut->a_meta_data >> (lane * 4)) & 0xfU);
}

uint8_t get_b_lane(const Vmfiu* dut, int lane) {
    const int bit = lane * 6;
    const int word = bit / 32;
    const int shift = bit % 32;
    uint64_t value = static_cast<uint64_t>(dut->b_meta_data[word]) >> shift;
    if ((shift > 26) && (word < 2)) {
        value |= static_cast<uint64_t>(dut->b_meta_data[word + 1]) << (32 - shift);
    }
    return static_cast<uint8_t>(value & 0x3fU);
}

bool expect_eq(const std::string& name, uint64_t got, uint64_t expected) {
    if (got != expected) {
        std::cerr << "ERROR: " << name << " got " << got
                  << " expected " << expected << " at t=" << sim_time << "\n";
        return false;
    }
    return true;
}

struct LaneExpect {
    uint8_t a_meta;
    uint8_t b_meta;
};

bool check_lanes(const Vmfiu* dut, const std::vector<LaneExpect>& expected) {
    for (size_t i = 0; i < expected.size(); ++i) {
        const uint8_t got_a = get_a_lane(dut, static_cast<int>(i));
        const uint8_t got_b = get_b_lane(dut, static_cast<int>(i));
        if (got_a != expected[i].a_meta || got_b != expected[i].b_meta) {
            std::cerr << "ERROR: lane" << i
                      << " got a_meta=" << static_cast<unsigned>(got_a)
                      << " b_meta=0x" << std::hex << static_cast<unsigned>(got_b)
                      << std::dec << " expected a_meta="
                      << static_cast<unsigned>(expected[i].a_meta)
                      << " b_meta=0x" << std::hex
                      << static_cast<unsigned>(expected[i].b_meta)
                      << std::dec << " at t=" << sim_time << "\n";
            return false;
        }
    }
    return true;
}

bool run_trip_transaction(Vmfiu* dut,
                          uint16_t a_mask,
                          uint64_t b_mask,
                          uint8_t b_col_valid,
                          bool a_last,
                          bool b_group_last) {
    set_idle_inputs(dut);

    dut->en = 1;
    dut->mode = 1;
    tick(dut);

    dut->en = 0;
    dut->a_bitmask = a_mask;
    dut->a_last = a_last ? 1 : 0;
    dut->a_in_valid = 1;
    tick(dut);

    dut->a_in_valid = 0;
    dut->b_bitmask = b_mask;
    dut->b_col_valid = b_col_valid;
    dut->b_group_last = b_group_last ? 1 : 0;
    dut->b_in_valid = 1;
    tick(dut);

    dut->b_in_valid = 0;
    tick(dut);

    return expect_eq("meta_valid", dut->meta_valid, 1);
}

bool test_standard_mode(Vmfiu* dut) {
    reset(dut);

    dut->en = 1;
    dut->mode = 0;
    dut->a_in_valid = 1;
    dut->b_in_valid = 1;
    dut->a_last = 1;
    dut->a_bitmask = 0xffffU;
    dut->b_bitmask = pack_b(0xffffU, 0xffffU, 0xffffU, 0xffffU);
    dut->b_col_valid = 3;

    for (int i = 0; i < 8; ++i) {
        tick(dut);
        if (dut->meta_valid != 0) {
            std::cerr << "ERROR: standardIP mode asserted meta_valid at cycle " << i << "\n";
            return false;
        }
    }

    return expect_eq("standardIP effectual_count", dut->effectual_count, 0);
}

bool test_basic_trip(Vmfiu* dut) {
    reset(dut);

    const uint16_t a = 0x0029U;
    const uint16_t b0 = 0x0021U;
    const uint16_t b1 = 0x0028U;

    if (!run_trip_transaction(dut, a, pack_b(b0, b1, 0, 0), 1, true, false)) {
        return false;
    }

    if (!expect_eq("basic effectual_count", dut->effectual_count, 4)) {
        return false;
    }

    const std::vector<LaneExpect> expected = {
        {0, 0x00},
        {2, 0x01},
        {1, 0x10},
        {2, 0x11},
        {0, 0x00},
    };
    return check_lanes(dut, expected);
}

bool test_four_column_trip(Vmfiu* dut) {
    reset(dut);

    const uint16_t a = 0x0055U;   // k=0,2,4,6
    const uint16_t b0 = 0x0021U;  // k=0,5 -> local(k0)=0
    const uint16_t b1 = 0x0006U;  // k=1,2 -> local(k2)=1
    const uint16_t b2 = 0x0018U;  // k=3,4 -> local(k4)=1
    const uint16_t b3 = 0x0062U;  // k=1,5,6 -> local(k6)=2

    if (!run_trip_transaction(dut, a, pack_b(b0, b1, b2, b3), 3, true, false)) {
        return false;
    }

    if (!expect_eq("four-column effectual_count", dut->effectual_count, 4)) {
        return false;
    }

    const std::vector<LaneExpect> expected = {
        {0, 0x00},
        {1, 0x11},
        {2, 0x21},
        {3, 0x32},
    };
    return check_lanes(dut, expected);
}

bool test_saturation(Vmfiu* dut) {
    reset(dut);

    if (!run_trip_transaction(dut, 0xffffU,
                              pack_b(0xffffU, 0xffffU, 0xffffU, 0xffffU),
                              3, true, false)) {
        return false;
    }

    if (!expect_eq("saturation effectual_count", dut->effectual_count, 16)) {
        return false;
    }

    std::vector<LaneExpect> expected;
    for (int i = 0; i < 16; ++i) {
        expected.push_back({static_cast<uint8_t>(i), static_cast<uint8_t>(i)});
    }
    return check_lanes(dut, expected);
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vmfiu dut;

    if (!test_standard_mode(&dut)) {
        return 1;
    }
    if (!test_basic_trip(&dut)) {
        return 1;
    }
    if (!test_four_column_trip(&dut)) {
        return 1;
    }
    if (!test_saturation(&dut)) {
        return 1;
    }

    std::cout << "MFIU TEST PASSED\n";
    return 0;
}
