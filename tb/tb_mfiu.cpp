#include "Vmfiu.h"
#include "verilated.h"
#ifndef NO_TRACE
#include "verilated_fst_c.h"
#else
struct VerilatedFstC {};
#endif

#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

namespace {

static vluint64_t sim_time = 0;
static constexpr vluint64_t HALF_PERIOD = 5;
constexpr int kMulRow = 16;
constexpr int kBFiber = 4;
constexpr int kBFifoSize = 13;

struct LaneExpect {
    uint8_t a_meta;
    uint8_t b_meta;
};

struct TxnExpect {
    uint8_t used_cols;
    uint8_t b_utilization;
    uint8_t effectual_count;
    bool complete_col;
    std::vector<LaneExpect> lanes;
};

const std::vector<uint16_t> kBfifo = {
    0x0001U,
    0x0005U,
    0x000AU,
    0x00F0U,
    0x0F00U,
    0xAAAAU,
    0x5555U,
    0x3333U,
    0xCCCCU,
    0xFFFAU,
    0xFFAAU,
    0xFFF0U,
    0xF0FFU,
};

uint64_t pack_b(uint16_t col0, uint16_t col1, uint16_t col2, uint16_t col3) {
    return (static_cast<uint64_t>(col0) << 0) |
           (static_cast<uint64_t>(col1) << 16) |
           (static_cast<uint64_t>(col2) << 32) |
           (static_cast<uint64_t>(col3) << 48);
}

uint64_t pack_b_window(const std::vector<uint16_t>& fifo, int head, int valid_cols) {
    uint16_t cols[kBFiber] = {0, 0, 0, 0};
    for (int i = 0; i < valid_cols; ++i) {
        cols[i] = fifo[static_cast<size_t>(head + i)];
    }
    return pack_b(cols[0], cols[1], cols[2], cols[3]);
}

void dump_eval(Vmfiu* dut, VerilatedFstC* fp) {
    dut->eval();
#ifndef NO_TRACE
    if (fp != nullptr) {
        fp->dump(sim_time);
    }
#endif
}

void init_wave(Vmfiu* dut, VerilatedFstC* fp) {
    dut->clk = 0;
    dump_eval(dut, fp);
}

void tick(Vmfiu* dut, VerilatedFstC* fp) {
    sim_time += HALF_PERIOD;
    dut->clk = 1;
    dump_eval(dut, fp);

    sim_time += HALF_PERIOD;
    dut->clk = 0;
    dump_eval(dut, fp);
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

void reset(Vmfiu* dut, VerilatedFstC* fp) {
    set_idle_inputs(dut);
    dut->rst_n = 0;
    tick(dut, fp);
    tick(dut, fp);
    dut->rst_n = 1;
    tick(dut, fp);
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

int intersection_count(uint16_t a, uint16_t b) {
    int count = 0;
    const uint16_t both = static_cast<uint16_t>(a & b);
    for (int k = 0; k < kMulRow; ++k) {
        if (((both >> k) & 1U) != 0U) {
            ++count;
        }
    }
    return count;
}

TxnExpect make_expected(uint16_t a, const std::vector<uint16_t>& window) {
    TxnExpect exp{};
    int used_cols = 0;
    int total = 0;

    for (int j = 0; j < static_cast<int>(window.size()); ++j) {
        const int col_count = intersection_count(a, window[static_cast<size_t>(j)]);
        if ((total + col_count) <= kMulRow) {
            total += col_count;
            used_cols = j + 1;
        } else {
            break;
        }
    }
    if (used_cols == 0) {
        used_cols = 1;
        total = intersection_count(a, window[0]);
    }

    exp.used_cols = static_cast<uint8_t>(used_cols);
    exp.b_utilization = static_cast<uint8_t>(used_cols - 1);
    exp.effectual_count = static_cast<uint8_t>(total);
    exp.complete_col = (used_cols == static_cast<int>(window.size()));

    for (int j = 0; j < used_cols; ++j) {
        int a_prefix = 0;
        int b_prefix = 0;
        const uint16_t b = window[static_cast<size_t>(j)];

        for (int k = 0; k < kMulRow; ++k) {
            const bool a_nz = ((a >> k) & 1U) != 0U;
            const bool b_nz = ((b >> k) & 1U) != 0U;
            if (a_nz && b_nz) {
                exp.lanes.push_back({static_cast<uint8_t>(a_prefix),
                                     static_cast<uint8_t>((j << 4) | b_prefix)});
            }
            if (a_nz) {
                ++a_prefix;
            }
            if (b_nz) {
                ++b_prefix;
            }
        }
    }

    return exp;
}

bool expect_eq(const std::string& name, uint64_t got, uint64_t expected) {
    if (got != expected) {
        std::cerr << "ERROR: " << name << " got " << got
                  << " expected " << expected << " at t=" << sim_time << "\n";
        return false;
    }
    return true;
}

bool wait_meta_valid(Vmfiu* dut, VerilatedFstC* fp, int max_cycles) {
    for (int cycle = 0; cycle < max_cycles; ++cycle) {
        tick(dut, fp);
        if (dut->meta_valid != 0) {
            return true;
        }
    }

    std::cerr << "ERROR: timed out waiting for meta_valid after "
              << max_cycles << " cycles at t=" << sim_time << "\n";
    return false;
}

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

    for (int lane = static_cast<int>(expected.size()); lane < kMulRow; ++lane) {
        const uint8_t got_a = get_a_lane(dut, lane);
        const uint8_t got_b = get_b_lane(dut, lane);
        if (got_a != 0U || got_b != 0U) {
            std::cerr << "ERROR: unused lane" << lane
                      << " got a_meta=" << static_cast<unsigned>(got_a)
                      << " b_meta=0x" << std::hex << static_cast<unsigned>(got_b)
                      << std::dec << " expected zero at t=" << sim_time << "\n";
            return false;
        }
    }

    return true;
}

void start_trip(Vmfiu* dut, VerilatedFstC* fp) {
    dut->en = 1;
    dut->mode = 1;
    tick(dut, fp);
    dut->en = 0;
    dut->mode = 0;
}

void send_a(Vmfiu* dut, VerilatedFstC* fp, uint16_t a_mask) {
    dut->a_bitmask = a_mask;
    dut->a_in_valid = 1;
    dut->a_last = 0;
    tick(dut, fp);
    dut->a_in_valid = 0;
}

bool test_standard_mode(Vmfiu* dut, VerilatedFstC* fp) {
    reset(dut, fp);

    dut->en = 1;
    dut->mode = 0;
    dut->a_in_valid = 1;
    dut->b_in_valid = 1;
    dut->a_last = 1;
    dut->b_group_last = 1;
    dut->a_bitmask = 0xffffU;
    dut->b_bitmask = pack_b(0xffffU, 0xffffU, 0xffffU, 0xffffU);
    dut->b_col_valid = 3;

    for (int i = 0; i < 8; ++i) {
        tick(dut, fp);
        if (dut->meta_valid != 0) {
            std::cerr << "ERROR: standardIP mode asserted meta_valid at cycle " << i << "\n";
            return false;
        }
    }

    if (!expect_eq("standardIP effectual_count", dut->effectual_count, 0)) {
        return false;
    }
    return expect_eq("standardIP b_utilization", dut->b_utilization, 0);
}

bool run_a_fifo(Vmfiu* dut,
                VerilatedFstC* fp,
                int a_index,
                uint16_t a_mask,
                bool is_last_a,
                int expected_tx_count) {
    int head = 0;
    int tx = 0;

    while (head < kBFifoSize) {
        const int head_before = head;
        const int remaining = kBFifoSize - head;
        const int valid_cols = remaining < kBFiber ? remaining : kBFiber;
        const bool b_group_last = (head + valid_cols) >= kBFifoSize;
        const bool a_last = is_last_a && b_group_last;

        std::vector<uint16_t> window;
        for (int i = 0; i < valid_cols; ++i) {
            window.push_back(kBfifo[static_cast<size_t>(head + i)]);
        }
        const TxnExpect exp = make_expected(a_mask, window);

        dut->b_bitmask = pack_b_window(kBfifo, head, valid_cols);
        dut->b_col_valid = static_cast<uint8_t>(valid_cols - 1);
        dut->b_group_last = b_group_last ? 1 : 0;
        dut->a_last = a_last ? 1 : 0;
        dut->b_in_valid = 1;
        tick(dut, fp);

        dut->b_in_valid = 0;
        if (!wait_meta_valid(dut, fp, 160)) {
            return false;
        }
        if (!expect_eq("fifo b_utilization", dut->b_utilization, exp.b_utilization)) {
            return false;
        }
        if (!expect_eq("fifo effectual_count", dut->effectual_count, exp.effectual_count)) {
            return false;
        }
        if (!check_lanes(dut, exp.lanes)) {
            return false;
        }

        const bool complete_col = (dut->b_utilization == dut->b_col_valid);
        if (complete_col != exp.complete_col) {
            std::cerr << "ERROR: complete_col mismatch at A" << a_index
                      << " TX" << tx << " got " << complete_col
                      << " expected " << exp.complete_col << "\n";
            return false;
        }

        std::cout << "A" << a_index << " TX" << tx
                  << " head=" << head_before
                  << " valid=" << valid_cols
                  << " used=" << static_cast<unsigned>(dut->b_utilization + 1)
                  << " b_col_valid=" << static_cast<unsigned>(dut->b_col_valid)
                  << " b_utilization=" << static_cast<unsigned>(dut->b_utilization)
                  << " complete=" << complete_col
                  << " b_group_last=" << b_group_last
                  << " a_last=" << a_last
                  << " count=" << static_cast<unsigned>(dut->effectual_count)
                  << "\n";

        head += static_cast<int>(dut->b_utilization) + 1;
        ++tx;

        if (head < kBFifoSize) {
            tick(dut, fp);
        }
    }

    return expect_eq("A transaction count", tx, expected_tx_count);
}

bool test_two_a_rows(Vmfiu* dut, VerilatedFstC* fp) {
    reset(dut, fp);

    start_trip(dut, fp);
    send_a(dut, fp, 0xFFFAU);
    if (!run_a_fifo(dut, fp, 0, 0xFFFAU, false, 8)) {
        return false;
    }

    // A0 complete_col=1, b_group_last=1, a_last=0 should transition to LOAD_A.
    tick(dut, fp);

    // In LOAD_A, a stray B valid must be ignored; a new OUT must not appear.
    dut->b_bitmask = pack_b(0x1234U, 0x5678U, 0x9ABCU, 0xDEF0U);
    dut->b_col_valid = 3;
    dut->b_group_last = 1;
    dut->a_last = 1;
    dut->b_in_valid = 1;
    tick(dut, fp);
    dut->b_in_valid = 0;
    if (!expect_eq("LOAD_A stray B meta_valid", dut->meta_valid, 0)) {
        return false;
    }

    send_a(dut, fp, 0xFFAAU);
    if (!run_a_fifo(dut, fp, 1, 0xFFAAU, true, 7)) {
        return false;
    }

    // A1 complete_col=1, b_group_last=1, a_last=1 should transition to IDLE.
    tick(dut, fp);
    dut->b_bitmask = pack_b(0xFFFFU, 0xFFFFU, 0xFFFFU, 0xFFFFU);
    dut->b_col_valid = 3;
    dut->b_group_last = 1;
    dut->a_last = 1;
    dut->b_in_valid = 1;
    for (int i = 0; i < 4; ++i) {
        tick(dut, fp);
        if (dut->meta_valid != 0) {
            std::cerr << "ERROR: IDLE accepted stray B after final A at cycle " << i << "\n";
            return false;
        }
    }
    dut->b_in_valid = 0;

    return true;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
#ifndef NO_TRACE
    Verilated::traceEverOn(true);
#endif

    Vmfiu dut;
    VerilatedFstC fp;
#ifndef NO_TRACE
    dut.trace(&fp, 99);
    fp.open("mfiu_wave.fst");
#endif
    init_wave(&dut, &fp);

    const bool ok = test_standard_mode(&dut, &fp) &&
                    test_two_a_rows(&dut, &fp);

#ifndef NO_TRACE
    fp.close();
#endif

    if (!ok) {
        return 1;
    }

    std::cout << "MFIU TEST PASSED\n";
    return 0;
}
