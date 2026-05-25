#include <stdint.h>

// linker symbols
extern unsigned int _dram_i_start;
extern unsigned int _dram_i_end;
extern unsigned int _imem_start;

extern unsigned int __data_start;
extern unsigned int __data_end;
extern unsigned int __data_paddr_start;

extern unsigned int __sdata_start;
extern unsigned int __sdata_end;
extern unsigned int __sdata_paddr_start;

// DMA base address
#define DMA_BASE        0x10020000
#define DMAEN_OFFSET    0x40     // Enable DMA
#define DESC_BASE_OFF   0x80     // Descriptor base address
// #define DMA_INT         0x04     // optional interrupt reg

// Descriptor memory location in DMEM
#define DESC1_ADDR      0x0002ff00
#define DESC2_ADDR      0x0002ff00 + 0x40
#define DESC3_ADDR      0x0002ff00 + 0x80

// typedef struct {
//     uint32_t DMASRC;
//     uint32_t DMADST;
//     uint32_t DMALEN;
//     uint32_t NEXT_DESC;
//     uint32_t EOC;   // 1 = last
// } dma_desc_t;

void boot(void)
{
    int *desc1 = (int *)0x0002ff00;
    int *desc2 = (int *)0x0002ff14;
    int *desc3 = (int *)0x0002ff28;

    volatile uint32_t *dma = (uint32_t *)DMA_BASE;

    // =====================================
    // Descriptor 1 (.text → IMEM)
    // =====================================
    desc1[0] = (uint32_t)&_dram_i_start;
    desc1[1] = (uint32_t)&_imem_start;
    desc1[2] = (uint32_t)(&_dram_i_end - &_dram_i_start + 1);
    desc1[3] = (uint32_t)0x0002ff14;   // chain to next
    desc1[4] = 0;

    // =====================================
    // Descriptor 2 (.data)
    // =====================================
    desc2[0] = (uint32_t)&__data_paddr_start;
    desc2[1] = (uint32_t)&__data_start;
    desc2[2] = (uint32_t)(&__data_end - &__data_start + 1);
    desc2[3] = (uint32_t)0x0002ff28;   // chain to next
    desc2[4] = 0;

    // =====================================
    // Descriptor 3 (.sdata)
    // =====================================
    desc3[0] = (uint32_t)&__sdata_paddr_start;
    desc3[1] = (uint32_t)&__sdata_start;
    desc3[2] = (uint32_t)(&__sdata_end - &__sdata_start + 1);
    desc3[3] = 0;                 // no next
    desc3[4] = 1;                       // last descriptor

    // =====================================
    // Enable interrupt (MEIE) DMA
    // =====================================
    asm volatile("li  t0, 0x8");
    asm volatile("csrs mstatus, t0");
    asm volatile("li t6, 0x800");
    asm volatile("csrw mie, t6");

    // =====================================
    // Start DMA (only one operation)
    // =====================================
    dma[DESC_BASE_OFF] = (uint32_t)desc1;   // first descriptor
    dma[DMAEN_OFFSET]  = 1;                 // enable DMA

    // wait for DMA interrupt
    asm volatile("wfi");                    // DMA done will wake CPU

    // disable DMA after done
    dma[DMAEN_OFFSET] = 0;

    // disable interrupt
    asm volatile("li t6, 0x000");
    asm volatile("csrw mie, t6");

    // execution returns to next boot stage
}
