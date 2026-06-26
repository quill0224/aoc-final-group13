#include <stdint.h>

// Register offsets (mapped via AXI S6 to 0x0005_0000 base address)
#define EPU_BASE          0x00050000
#define EPU_CTRL          (*(volatile uint32_t *)(EPU_BASE + 0x00))
#define EPU_STATUS        (*(volatile uint32_t *)(EPU_BASE + 0x04))
#define EPU_CFG_LENGTH    (*(volatile uint32_t *)(EPU_BASE + 0x08))
#define EPU_CFG_BITMASK   (*(volatile uint32_t *)(EPU_BASE + 0x0C))
#define EPU_CFG_PUSH      (*(volatile uint32_t *)(EPU_BASE + 0x10))
#define EPU_DATA_NZ       (*(volatile uint32_t *)(EPU_BASE + 0x14))
#define EPU_DATA_PUSH     (*(volatile uint32_t *)(EPU_BASE + 0x18))
#define EPU_NBASE         (*(volatile uint32_t *)(EPU_BASE + 0x1C))
#define EPU_DUMP          (*(volatile uint32_t *)(EPU_BASE + 0x20))
#define EPU_RESULT_BASE   (EPU_BASE + 0x40)

// Helper to access result registers (0-15)
#define EPU_RESULT(i)     (*(volatile uint32_t *)(EPU_RESULT_BASE + ((i) << 2)))

// Interrupt service routines (kept for compatibility with setup.S / isr.S)
volatile unsigned int *WDT_addr = (int *) 0x10010000;
#define MIP_MEIP (1 << 11)
#define MIP_MTIP (1 << 7)
#define MIP 0x344

void timer_interrupt_handler(void) {
    asm("csrsi mstatus, 0x0");
    WDT_addr[0x40] = 0;
    asm("j _start");
}

void external_interrupt_handler(void) {
    volatile unsigned int *dma_addr_boot = (int *) 0x10020000;
    asm("csrsi mstatus, 0x0");
    dma_addr_boot[0x40] = 0;
}

void trap_handler(void) {
    uint32_t mip;
    asm volatile("csrr %0, %1" : "=r"(mip) : "i"(MIP));
    if ((mip & MIP_MTIP) >> 7) {
        timer_interrupt_handler();
    }
    if ((mip & MIP_MEIP) >> 11) {
        external_interrupt_handler();
    }
}

extern unsigned int _test_start;

int main() {
    // 1. Reset / Initialize EPU Control Register
    // mode = 1 (TrIP/Sparse), first_pass = 1, clear_result = 0
    EPU_CTRL = 0x03;

    // 2. Feed 16 A fibers (is_b = 0)
    for (int i = 0; i < 16; i++) {
        uint32_t len  = (i == 0) ? 1 : ((i == 1) ? 1 : ((i == 2) ? 1 : 0));
        uint32_t mask = (i == 0) ? 8 : ((i == 1) ? 8 : ((i == 2) ? 32 : 0)); // index 3, 3, 5

        // Poll until cfg_busy (STATUS[5]) is 0
        while (EPU_STATUS & (1 << 5));

        EPU_CFG_LENGTH  = len;
        EPU_CFG_BITMASK = mask;
        EPU_CFG_PUSH    = 1;

        if (len > 0) {
            uint32_t val = (i == 0) ? 5 : ((i == 1) ? 10 : ((i == 2) ? 2 : 0));
            // Poll until data_busy (STATUS[6]) is 0
            while (EPU_STATUS & (1 << 6));
            EPU_DATA_NZ   = val;
            EPU_DATA_PUSH = 1;
        }
    }

    // 3. Feed 16 B columns (is_b = 1)
    for (int j = 0; j < 16; j++) {
        uint32_t len  = (j == 0) ? 1 : ((j == 1) ? 1 : 0);
        uint32_t mask = (j == 0) ? 8 : ((j == 1) ? 32 : 0); // index 3, 5

        // Poll until cfg_busy (STATUS[5]) is 0
        while (EPU_STATUS & (1 << 5));

        EPU_CFG_LENGTH  = (1 << 15) | len; // bit 15 = is_b
        EPU_CFG_BITMASK = mask;
        EPU_CFG_PUSH    = 1;

        if (len > 0) {
            uint32_t val = (j == 0) ? 4 : ((j == 1) ? 7 : 0);
            // Poll until data_busy (STATUS[6]) is 0
            while (EPU_STATUS & (1 << 6));
            EPU_DATA_NZ   = val;
            EPU_DATA_PUSH = 1;
        }
    }

    // 4. Wait for computation to finish (Poll STATUS.compute_done == 1)
    while ((EPU_STATUS & (1 << 2)) == 0);

    // 5. Read back results
    EPU_NBASE = 0;
    uint32_t col0_val0 = 0;
    uint32_t col0_val1 = 0;
    uint32_t col1_val2 = 0;

    // Dump Column 0
    EPU_DUMP = 0;
    while ((EPU_STATUS & (1 << 4)) == 0); // Wait for result_valid
    col0_val0 = EPU_RESULT(0); // Expected: 5 * 4 = 20
    col0_val1 = EPU_RESULT(1); // Expected: 10 * 4 = 40

    // Dump Column 1
    EPU_DUMP = 1;
    while ((EPU_STATUS & (1 << 4)) == 0); // Wait for result_valid
    col1_val2 = EPU_RESULT(2); // Expected: 2 * 7 = 14

    // 6. Write results to test section in DRAM (TEST_START)
    uint32_t *dram_out = (uint32_t *)&_test_start;
    dram_out[0] = col0_val0;
    dram_out[1] = col0_val1;
    dram_out[2] = col1_val2;

    return 0;
}
