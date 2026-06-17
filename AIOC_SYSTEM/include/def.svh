//================================================
// Auther:      Chen Yun-Ru (May)
// Filename:    def.svh
// Description: Hart defination
// Version:     0.1
//================================================
// `ifndef DEF_SVH
// `define DEF_SVH

// Cache
`define CACHE_BLOCK_BITS 2
`define CACHE_INDEX_BITS 5
`define CACHE_TAG_BITS 23
`define CACHE_DATA_BITS 128
`define CACHE_LINES 2**(`CACHE_INDEX_BITS)
`define CACHE_WRITE_BITS 16
`define CACHE_TYPE_BITS 3
`define CACHE_BYTE `CACHE_TYPE_BITS'b000
`define CACHE_HWORD `CACHE_TYPE_BITS'b001
`define CACHE_WORD `CACHE_TYPE_BITS'b010
`define CACHE_BYTE_U `CACHE_TYPE_BITS'b100
`define CACHE_HWORD_U `CACHE_TYPE_BITS'b101

//**************************************************************************//
//                               CDC Bitwidth                               //
//**************************************************************************//
`define READ_ADDRESS_BITS           50
`define READ_SLAVE_ADDRESS_BITS     54
`define READ_DATA_BITS              40
`define READ_SLAVE_DATA_BITS        44
`define WRITE_ADDRESS_BITS          50
`define WRITE_SLAVE_ADDRESS_BITS    54
`define WRITE_DATA_BITS             38
`define WRITE_RESPONSE_BITS         7
`define WRITE_SLAVE_RESPONSE_BITS   11

//**************************************************************************//
//                      Define states for the AXI FSM                       //
//**************************************************************************//
// IM Read
`define IM_READ_IDLE 2'd0
`define CPU0_READ_IM 2'd1
`define CPU1_READ_IM 2'd2
`define DMAM_READ_IM 2'd3
// DM Read
`define DM_READ_IDLE 2'd0
`define CPU0_READ_DM 2'd1
`define CPU1_READ_DM 2'd2
`define DMAM_READ_DM 2'd3
// DRAM Read
`define DRAM_READ_IDLE 2'd0
`define CPU0_READ_DRAM 2'd1
`define CPU1_READ_DRAM 2'd2
`define DMAM_READ_DRAM 2'd3
// ROM Read
`define ROM_READ_IDLE 2'd0
`define CPU0_READ_ROM 2'd1
`define CPU1_READ_ROM 2'd2
`define DMAM_READ_ROM 2'd3
// IM Write
`define IM_WRITE_IDLE 2'd0
`define CPU1_WRITE_IM 2'd1
`define DMAM_WRITE_IM 2'd2
// DM Write
`define DM_WRITE_IDLE 2'd0
`define CPU1_WRITE_DM 2'd1
`define DMAM_WRITE_DM 2'd2
// DRAM Write
`define DRAM_WRITE_IDLE 2'd0
`define CPU1_WRITE_DRAM 2'd1
`define DMAM_WRITE_DRAM 2'd2
// WDT Write
`define WDT_WRITE_IDLE 1'd0
`define CPU1_WRITE_WDT 1'd1
// DMA Write
`define DMA_WRITE_IDLE 1'd0
`define CPU1_WRITE_DMA 1'd1
// Define Round Robin Grant
`define GRANT_CPU0 3'b001
`define GRANT_CPU1 3'b010
`define GRANT_DMAM 3'b100


//**************************************************************************//
//                                  CACHE                                   //
//**************************************************************************//
`define HIT_WAY0        2'd0
`define HIT_WAY1        2'd1
`define MISS            2'd2
`define ALL_ONE_23BITS  23'b1111_1111_1111_1111_1111_111      
`define ALL_ONE_128BITS 128'hffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff
//I cache state
`define L1_ICACHE_IDLE  2'd0
`define L1_ICACHE_R     2'd1
`define L1_ICACHE_RM    2'd2
//D cache state
`define L1_DCACHE_IDLE  3'd0
`define L1_DCACHE_R     3'd1
`define L1_DCACHE_RM    3'd2
`define L1_DCACHE_WM    3'd3
`define L1_DCACHE_WH    3'd4

//**************************************************************************//
//                                 OPCODE                                   //
//**************************************************************************//
`define	OPCODE	 		inst[6:0]
// R TYPE
`define	R_TYPE	 		7'b0110011
// I TYPE
`define I_TYPE 			7'b0010011
`define LOAD_I_OPCODE	7'b0000011
`define JALR_OPCODE		7'b1100111
// S TYPE
`define STORE_I_TYPE 	7'b0100011
// B TYPE
`define B_TYPE	 		7'b1100011
// U TYPE
`define AUIPC_OPCODE	7'b0010111
`define LUI_OPCDOE		7'b0110111
// J TYPE
`define J_TYPE			7'b1101111
// F TYPE
`define LOAD_F_OPCODE	7'b0000111
`define F_TYPE			7'b1010011
`define STORE_F_TYPE	7'b0100111
//CSR
`define CSR_OPCODE		7'b1110011
`define MPP			12:11
`define MPIE		7
`define MIE			3
`define MEIP		11
`define MTIP		7
`define MEIE		11
`define MTIE		7
`define mstatus_addr	12'h300	
`define mie_addr	12'h304	
`define MRET_imm	5'b00010
`define WFI_imm		5'b00101
`define CSR_IDLE 2'd0
`define WFI 2'd1
`define WRET 2'd2

//**************************************************************************//
//                           MASTER & SLAVE                                 //
//**************************************************************************//
// Slave  state
`define IDLE 2'd0
`define READ 2'd1
`define WRITE 2'd2
`define RESPONSE 2'd3
// Master 
`define M0ID 4'd0
`define M0LEN 8'd0
`define M0SIZE 3'd2
`define M0BURST 2'd1
`define M1ID 4'd1
`define M1LEN 8'd0
`define M1SIZE 3'd2
`define M1BURST 2'd1
// M0 state
`define M0_IDLE 2'd0
`define M0_READADDR 2'd1
`define M0_READDATA 2'd2
`define M0_WAITSTALL 2'd3
// M1 Read state
`define M1_RIDLE 2'd0
`define M1_READADDR 2'd1
`define M1_READDATA 2'd2
`define M1_RWAITSTALL 2'd3
// M1 Write state
`define M1_WIDLE 3'd0
`define M1_WRITEADDR 3'd1
`define M1_WRITEDATA 3'd2
`define M1_RESPONSE 3'd3
`define M1_WWAITSTALL 3'd4

//**************************************************************************//
//                                 DRAM                                     //
//**************************************************************************//
// Slave  state
`define AXI_DRAM_IDLE 2'd0
`define AXI_DRAM_READ 2'd1
`define AXI_DRAM_WRITE 2'd2
`define AXI_DRAM_RESPONSE 2'd3
//DRAM controller
`define DRAM_IDLE 3'd0
`define DRAM_ROW_ADDR 3'd1
`define DRAM_COLUMN_ADDR 3'd2
`define DRAM_WAIT 3'd3
`define DRAM_WRITEBACK 3'd4

//**************************************************************************//
//                                 DMA                                      //
//**************************************************************************//
// DMA Module State Define
// `define DMA_IDLE 2'd0
// `define DMA_BUSY 2'd1
// `define DMA_INTERRUPT 2'd2
// // DMA Wrapper Slave State Define
// `define DMA_S_IDLE 2'd0
// `define DMA_S_WRITE 2'd1
// `define DMA_S_RESPONSE 2'd2
// // DMA Wrapper Master State Define
// `define DMA_M_IDLE 3'd0
// `define DMA_M_READ_ADDR 3'd1
// `define DMA_M_READ_DATA 3'd2
// `define DMA_M_WRITE_ADDR 3'd3
// `define DMA_M_WRITE_DATA 3'd4
// `define DMA_M_WRITE_RESPONSE 3'd5
// `define DMA_M_WAITEN 3'd6
// // DMA Wrapper Slave Memory Define
// `define MEM_DMAEN   32'h10020100
// `define MEM_DMASRC  32'h10020200
// `define MEM_DMADST  32'h10020300
// `define MEM_DMALEN  32'h10020400
// // DMA Spec 
// `define DMA_MASTER_ID 4'd2
// `define DMA_BURST_LEN 8'd255
// `define DMA_BURST_SIZE 3'd2
// `define DMA_BURST_TYPE 2'd1

//**************************************************************************//
//                                 ROM                                      //
//**************************************************************************//
// Define ROM State
`define ROM_IDLE 1'd0
`define ROM_READ 1'd1

//**************************************************************************//
//                                 WDT                                      //
//**************************************************************************//
`define MEM_WDEN 32'h10010100
`define MEM_WDLIVE 32'h10010200
`define MEM_WTOCNT 32'h10010300
// Define Watch Dog Timer Module State
`define WDT_IDLE 2'd0
`define WDT_COUNT 2'd1
`define WDT_INTERRUPT 2'd2
// Define WDT Wrapper Write State
`define WDT_IDLE 2'd0
`define WDT_WRITE 2'd1
`define WDT_RESPONSE 2'd2


// `endif


