`ifndef ASIC
`define ASIC

// ============================================================================
// ASIC.svh — Trapezoid Sparse CNN Accelerator
//
// Worst-case target: VGG8 conv3-512
//   IP=512, OP=512, H=W=28, R=S=3
//   K = IP x R x S = 4608
//   M = H  x W     = 784
//   N = OP         = 512
//
// AXI_DATA_BITS = 32bits (4bytes per beat), from AXI_define.svh
// All GLB accesses are 32bits wide to match AXI
// ============================================================================

// ----------------------------------------------------------------------------
// Data Width
// Matches AXI_DATA_BITS = 32
// GLB read/write granularity = 32bits = 1 word
// ----------------------------------------------------------------------------
`define DATA_BITS               32
`define GLB_ADDR_BITS           16
`define GLB_DATA_BITS           32      // matches AXI_DATA_BITS

// ----------------------------------------------------------------------------
// Packet Format (Updated: 160-bit Perfectly Aligned)
// [ length 16b ][ bitmask 16b ][ NZ values 128b ] = 160bits
// Padded perfectly to 160bits (20bytes) for 4-byte AXI alignment
// 20bytes / 4bytes = 5 AXI beats per packet
// MC reads 5 x 32bit words from GLB and assembles one packet internally:
//   Word 0: {Length[15:0], Bitmask[15:0]}
//   Word 1-4: Data
// ----------------------------------------------------------------------------
`define PKT_LENGTH_BITS         16
`define PKT_BITMASK_BITS        16
`define PKT_NZ_BITS             128
`define PKT_TOTAL_BITS          160     // 16 + 16 + 128
`define PKT_BYTES               20      // 160 / 8
`define PKT_BEATS               5       // 20bytes / 4bytes per beat
`define PKT_WORDS               5       // alias for PKT_BEATS

// ----------------------------------------------------------------------------
// Operation Mode (2bits)
// 2'b00 = StandardIP : dense dataflow, MFIU bypassed
// 2'b01 = TrIP       : sparse dataflow, MFIU enabled
// 2'b10, 2'b11       : reserved for future extension
// ----------------------------------------------------------------------------
`define MODE_STD_IP             2'b00
`define MODE_TRIP               2'b01
`define MODE_RESERVED_2         2'b10
`define MODE_RESERVED_3         2'b11

// ----------------------------------------------------------------------------
// DMA Transfer Mode (2bits)
// ----------------------------------------------------------------------------
`define DMA_MODE_IFMAP          2'd0
`define DMA_MODE_FILTER         2'd1
`define DMA_MODE_BIAS           2'd2    // reserved
`define DMA_MODE_OFMAP          2'd3

// ----------------------------------------------------------------------------
// PE Array (16x16 Trapezoid)
// Coordinate convention:
//   bottom-right = PE(XID=0,  YID=0)  → index 0
//   bottom-left  = PE(XID=15, YID=0)  → index 15
//   top-left     = PE(XID=15, YID=15) → index 255
// ----------------------------------------------------------------------------
`define PE_ARRAY_W              16
`define PE_ARRAY_H              16
`define PE_NUMS                 256     // 16 x 16
`define XID_BITS                4       // 2^4 = 16
`define YID_BITS                4       // 2^4 = 16
`define DEFAULT_XID             4'hF
`define DEFAULT_YID             4'hF

// Filter spatial dimensions
`define FILT_R                  3
`define FILT_S                  3

// GLB bank count (single bank for demo, expandable for ping-pong)
`define GLB_BANK_SIZE           1

// ----------------------------------------------------------------------------
// Tiling (VGG8 conv3-512 worst case upper bounds)
// N tiles : 512  / 16 = 32
// K tiles : 4608 / 16 = 288
// M tiles : 784  / 16 = 49
//
// Counter bit widths: 1 extra bit beyond minimum for overflow safety
//   n_cnt : 0~31  → 5bits min, use 6
//   k_cnt : 0~287 → 9bits min, use 10
//   m_cnt : 0~48  → 6bits min, use 7
// ----------------------------------------------------------------------------
`define N_TILE_SIZE             16
`define K_TILE_SIZE             16
`define M_TILE_SIZE             16

`define N_TILES_MAX             32
`define K_TILES_MAX             288
`define M_TILES_MAX             49

`define N_CNT_BITS              6
`define K_CNT_BITS              10
`define M_CNT_BITS              7

// Packets per tile and counter width
`define PKTS_PER_TILE           16
`define PKT_CNT_BITS            5       // ceil(log2(16)) + 1

// ----------------------------------------------------------------------------
// GLB Layout — Single Continuous SRAM Macro
//
// Physical: ADFP process, 1KB SRAM macro
// Data width: 32bits (matches AXI, one word per access)
//
// Byte map:
//   GLB_A [0x0000 ~ 0x013F]  320bytes  ifmap  tile (16 pkts x 20bytes)
//   GLB_B [0x0140 ~ 0x027F]  320bytes  filter tile (16 pkts x 20bytes)
//   GLB_C [0x0280 ~ 0x037F]  256bytes  output tile (16x16 x 1byte @ 8bit)
//   Total: 896bytes < 1024bytes ✓
//
// Word map (32bits per word):
//   GLB_A [word 0   ~ word 79 ]  80 words
//   GLB_B [word 80  ~ word 159]  80 words
//   GLB_C [word 160 ~ word 223]  64 words
//   Total: 224 words
//
// GLB_ADDR_BITS=16 addresses bytes; RTL internally shifts >>2 for word index
// ----------------------------------------------------------------------------
`define GLB_A_BASE              16'h0000
`define GLB_A_SIZE              320
`define GLB_A_END               16'h013F

`define GLB_B_BASE              16'h0140
`define GLB_B_SIZE              320
`define GLB_B_END               16'h027F

`define GLB_C_BASE              16'h0280
`define GLB_C_SIZE              256     // 16x16 output elements, 8bit each
`define GLB_C_END               16'h037F

`define GLB_TOTAL_BYTES         896

// ----------------------------------------------------------------------------
// GLB Access Modes (keep compatible with reference design)
// ----------------------------------------------------------------------------
`define BYTE_MODE               0
`define WORD_MODE               1

`define GLB_MUX_ASIC            0       // MC is reading
`define GLB_MUX_DMA             1       // DMA is writing

`define GLB_DO_PSUM             0
`define GLB_DO_OFMAP            1

`define NO_PAD                  0
`define WITH_PAD                1

// ----------------------------------------------------------------------------
// MC Interface
// ----------------------------------------------------------------------------
`define MC_PKT_CNT_BITS         `PKT_CNT_BITS

// ----------------------------------------------------------------------------
// MMIO Register Map
// AXI4-Lite slave, base: 0x1004_0000
// All registers 32bits, 4-byte aligned
// Write all params first, assert asic_en last
// Poll ASIC_DONE_OFFSET to detect completion
// ----------------------------------------------------------------------------
`define ADDR_MMIO                       32'h1004_0000

// [W] Control
`define ASIC_ENABLE_OFFSET              (`ADDR_MMIO + 32'h00)
// [1:0] operation_mode
`define ASIC_OP_MODE_OFFSET             (`ADDR_MMIO + 32'h04)

// [W] PE mapping params (packed)
// [31:28]=e[3:0] [27:25]=p[2:0] [24:22]=q[2:0] [21:19]=r[2:0] [18:16]=t[2:0]
`define ASIC_MAPPING_PARAM_OFFSET       (`ADDR_MMIO + 32'h08)

// [W] Tiling counts (software pre-computes from layer shape)
// [5:0]  N_tiles (max 32)
// [9:0]  K_tiles (max 288)
// [6:0]  M_tiles (max 49)
`define ASIC_N_TILES_OFFSET             (`ADDR_MMIO + 32'h0C)
`define ASIC_K_TILES_OFFSET             (`ADDR_MMIO + 32'h10)
`define ASIC_M_TILES_OFFSET             (`ADDR_MMIO + 32'h14)

// [W] Packets per tile
`define ASIC_PKT_COUNT_OFFSET           (`ADDR_MMIO + 32'h18)

// [W] DRAM base addresses (32bit AXI addresses)
`define ASIC_IFMAP_BASE_OFFSET          (`ADDR_MMIO + 32'h1C)
`define ASIC_FILTER_BASE_OFFSET         (`ADDR_MMIO + 32'h20)
`define ASIC_OPSUM_BASE_OFFSET          (`ADDR_MMIO + 32'h24)

// [W] Dynamic tile byte lengths (must be 4-byte aligned)
`define ASIC_COMP_A_LEN_OFFSET          (`ADDR_MMIO + 32'h28)
`define ASIC_COMP_B_LEN_OFFSET          (`ADDR_MMIO + 32'h2C)

// [W] GLB base addresses (default matches GLB layout above, kept flexible)
`define ASIC_GLB_A_BASE_OFFSET          (`ADDR_MMIO + 32'h30)
`define ASIC_GLB_B_BASE_OFFSET          (`ADDR_MMIO + 32'h34)
`define ASIC_GLB_C_BASE_OFFSET          (`ADDR_MMIO + 32'h38)

// [R] Status
`define ASIC_DONE_OFFSET                (`ADDR_MMIO + 32'h3C)

`endif // ASIC
