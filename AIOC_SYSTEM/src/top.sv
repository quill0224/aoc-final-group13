
// `define AXI_ID_BITS 4
// `define AXI_IDS_BITS 8
// `define AXI_ADDR_BITS 32
// `define AXI_LEN_BITS 4
// `define AXI_SIZE_BITS 3
// `define AXI_DATA_BITS 32
// `define AXI_STRB_BITS 4
// `define AXI_LEN_ONE 4'h0
// `define AXI_SIZE_BYTE 3'b000
// `define AXI_SIZE_HWORD 3'b001
// `define AXI_SIZE_WORD 3'b010
// `define AXI_BURST_INC 2'h1
// `define AXI_STRB_WORD 4'b1111
// `define AXI_STRB_HWORD 4'b0011
// `define AXI_STRB_BYTE 4'b0001
// `define AXI_RESP_OKAY 2'h0
// `define AXI_RESP_SLVERR 2'h2
// `define AXI_RESP_DECERR 2'h3

module top (
    // input                clk,
    // input                clk2,
    // input                rst,
    // input                rst2,
    input                cpu_clk,
    input                axi_clk,
    input                rom_clk,
    input                dram_clk,
    input                cpu_rst,
    input                axi_rst,
    input                rom_rst,
    input                dram_rst,
    //DRAM
    input   [31:0]       DRAM_Q,
    input                DRAM_valid,
    output  logic        DRAM_CSn,
    output  logic [3:0]  DRAM_WEn,
    output  logic        DRAM_RASn,
    output  logic        DRAM_CASn,
    output  logic [10:0] DRAM_A,
    output  logic [31:0] DRAM_D,
    //ROM
    input   [31:0]       ROM_out,
    output  logic        ROM_read,
    output  logic        ROM_enable,
    output  logic [11:0] ROM_address
    
);

logic interrupt    , WTO;
logic interrupt_CDC, WTO_CDC;
logic interrupt_dma;

assign interrupt = interrupt_dma;

    // ================== AXI Master0 (Instruction) ==================
    // Read Address
    logic [`AXI_ID_BITS-1:0]   ARID_M0;
    logic [`AXI_ADDR_BITS-1:0] ARADDR_M0;
    logic [3:0]                ARLEN_M0;
    logic [`AXI_SIZE_BITS-1:0] ARSIZE_M0;
    logic [1:0]                ARBURST_M0;
    logic                      ARVALID_M0;
    logic                      ARREADY_M0;
    // Read Data
    logic [`AXI_ID_BITS-1:0]   RID_M0;
    logic [`AXI_DATA_BITS-1:0] RDATA_M0;
    logic [1:0]                RRESP_M0;
    logic                      RLAST_M0;
    logic                      RVALID_M0;
    logic                      RREADY_M0;

    //AR_channel   M0
    logic [45:0]               arWire_M0_CDC;
    logic [49:0]               arWire_M0_CDC_AXI;
    logic                      ARVALID_M0_CDC;
    logic                      ARREADY_M0_CDC;
    //R_channel    M0
    logic [39:0]               rWire_M0_CDC;
    logic [49:0]               rWire_M0_CDC_AXI;
    logic                      RREADY_M0_CDC;
    logic                      RVALID_M0_CDC;

    // ================== AXI Master1 (Data) ==================
    // Read Address
    logic [`AXI_ID_BITS-1:0]   ARID_M1;
    logic [`AXI_ADDR_BITS-1:0] ARADDR_M1;
    logic [3:0]  ARLEN_M1;
    logic [`AXI_SIZE_BITS-1:0] ARSIZE_M1;
    logic [1:0]                ARBURST_M1;
    logic                      ARVALID_M1;
    logic                      ARREADY_M1;
    // Read Data
    logic [`AXI_ID_BITS-1:0]   RID_M1;
    logic [`AXI_DATA_BITS-1:0] RDATA_M1;
    logic [1:0]                RRESP_M1;
    logic                      RLAST_M1;
    logic                      RVALID_M1;
    logic                      RREADY_M1;
    // Write Address
    logic [`AXI_ID_BITS-1:0]   AWID_M1;
    logic [`AXI_ADDR_BITS-1:0] AWADDR_M1;
    logic [3:0]  AWLEN_M1;
    logic [`AXI_SIZE_BITS-1:0] AWSIZE_M1;
    logic [1:0]                AWBURST_M1;
    logic                      AWVALID_M1;
    logic                      AWREADY_M1;
    // Write Data
    logic [`AXI_DATA_BITS-1:0] WDATA_M1;
    logic [`AXI_STRB_BITS-1:0] WSTRB_M1;
    logic                      WLAST_M1;
    logic                      WVALID_M1;
    logic                      WREADY_M1;
    // Write Response
    logic [`AXI_ID_BITS-1:0]   BID_M1;
    logic [1:0]                BRESP_M1;
    logic                      BVALID_M1;
    logic                      BREADY_M1;

  //AR_channel   M1
    logic [45:0]                     arWire_M1_CDC;
    logic [49:0]                     arWire_M1_CDC_AXI;
    logic                            ARVALID_M1_CDC;
    logic                            ARREADY_M1_CDC;
    //R_channel    M1
    logic [39:0]                     rWire_M1_CDC;
    logic [49:0]                     rWire_M1_CDC_AXI;
    logic                            RVALID_M1_CDC;
    logic                            RREADY_M1_CDC;
    //AW_channel   M1
    logic [45:0]                     awWire_M1_CDC;
    logic [49:0]                     awWire_M1_CDC_AXI;
    logic                            AWVALID_M1_CDC;
    logic                            AWREADY_M1_CDC;
    //W_channel    M1
    logic [37:0]                     wWire_M1_CDC;
    logic [49:0]                     wWire_M1_CDC_AXI;
    logic                            WVALID_M1_CDC;
    logic                            WREADY_M1_CDC;
    //B_channel    M1
    logic [8:0]                     bWire_M1_CDC;
    logic [49:0]                    bWire_M1_CDC_AXI;
    logic                           BVALID_M1_CDC;
    logic                           BREADY_M1_CDC;

// ================== AXI Master2 (DMA) ==================
    // Read Address
    logic [`AXI_ID_BITS-1:0]   ARID_M2;
    logic [`AXI_ADDR_BITS-1:0] ARADDR_M2;
    logic [3:0]  ARLEN_M2;
    logic [`AXI_SIZE_BITS-1:0] ARSIZE_M2;
    logic [1:0]                ARBURST_M2;
    logic                      ARVALID_M2;
    logic                      ARREADY_M2;
    // Read Data
    logic [`AXI_ID_BITS-1:0]      RID_M2;
    logic [`AXI_DATA_BITS-1:0]  RDATA_M2;
    logic [1:0]                 RRESP_M2;
    logic                       RLAST_M2;
    logic                      RVALID_M2;
    logic                      RREADY_M2;
    // Write Address
    logic [`AXI_ID_BITS-1:0]      AWID_M2;
    logic [`AXI_ADDR_BITS-1:0]  AWADDR_M2;
    logic [3:0]    AWLEN_M2;
    logic [`AXI_SIZE_BITS-1:0]  AWSIZE_M2;
    logic [1:0]                AWBURST_M2;
    logic                      AWVALID_M2;
    logic                      AWREADY_M2;
    // Write Data
    logic [`AXI_DATA_BITS-1:0]  WDATA_M2;
    logic [`AXI_STRB_BITS-1:0]  WSTRB_M2;
    logic                       WLAST_M2;
    logic                      WVALID_M2;
    logic                      WREADY_M2;
    // Write Response
    logic [`AXI_ID_BITS-1:0]   BID_M2;
    logic [1:0]                BRESP_M2;
    logic                      BVALID_M2;
    logic                      BREADY_M2;

    //AR_channel   DMA  (Master)
    logic [45:0]                     arWire_M2_CDC;
    logic [49:0]                     arWire_M2_CDC_AXI;
    logic                            ARVALID_M2_CDC;
    logic                            ARREADY_M2_CDC;
    //R_channel    DMA  (Master)
    logic [39:0]                     rWire_M2_CDC;
    logic [49:0]                     rWire_M2_CDC_AXI;
    logic                            RVALID_M2_CDC;
    logic                            RREADY_M2_CDC;
    //AW_channel   DMA  (Master)
    logic [45:0]                     awWire_M2_CDC;
    logic [49:0]                     awWire_M2_CDC_AXI;
    logic                            AWVALID_M2_CDC;
    logic                            AWREADY_M2_CDC;
    //W_channel    DMA  (Master)
    logic [37:0]                     wWire_M2_CDC;
    logic [49:0]                     wWire_M2_CDC_AXI;
    logic                            WVALID_M2_CDC;
    logic                            WREADY_M2_CDC;
    //B_channel    DMA  (Master)
    logic [6:0]                     bWire_M2_CDC;
    logic [49:0]                     bWire_M2_CDC_AXI;
    logic                           BVALID_M2_CDC;
    logic                           BREADY_M2_CDC;

    // ================== AXI Slave0 (ROM) ==================
    // Write Address
    logic [`AXI_IDS_BITS-1:0]  AWID_S0;
    logic [`AXI_ADDR_BITS-1:0] AWADDR_S0;
    logic [3:0]  AWLEN_S0;
    logic [`AXI_SIZE_BITS-1:0] AWSIZE_S0;
    logic [1:0]                AWBURST_S0;
    logic                      AWVALID_S0;
    logic                      AWREADY_S0;
    // Write Data
    logic [`AXI_DATA_BITS-1:0] WDATA_S0;
    logic [`AXI_STRB_BITS-1:0] WSTRB_S0;
    logic                      WLAST_S0;
    logic                      WVALID_S0;
    logic                      WREADY_S0;
    // Write Response
    logic [`AXI_IDS_BITS-1:0]  BID_S0;
    logic [3:0]                BRESP_S0;
    logic                      BVALID_S0;
    logic                      BREADY_S0;
    // Read Address
    logic [`AXI_IDS_BITS-1:0]  ARID_S0;
    logic [`AXI_ADDR_BITS-1:0] ARADDR_S0;
    logic [3:0]                ARLEN_S0;
    logic [`AXI_SIZE_BITS-1:0] ARSIZE_S0;
    logic [1:0]                ARBURST_S0;
    logic                      ARVALID_S0;
    logic                      ARREADY_S0;
    // Read Data
    logic [`AXI_IDS_BITS-1:0]  RID_S0;
    logic [`AXI_DATA_BITS-1:0] RDATA_S0;
    logic [1:0]                RRESP_S0;
    logic                      RLAST_S0;
    logic                      RVALID_S0;
    logic                      RREADY_S0;

    //AR_channel   ROM
    logic [49:0]                     arWire_S0_CDC;
    logic [49:0]                     arWire_S0_CDC_AXI;
    logic                            ARVALID_S0_CDC;
    logic                            ARREADY_S0_CDC;

    //R_channel    ROM
    logic [43:0]                     rWire_S0_CDC;
    logic [49:0]                     rWire_S0_CDC_AXI;
    logic                            RREADY_S0_CDC;
    logic                            RVALID_S0_CDC;

    // ================== AXI Slave1 (IM) ==================
    // Write Address
    logic [`AXI_IDS_BITS-1:0]  AWID_S1;
    logic [`AXI_ADDR_BITS-1:0] AWADDR_S1;
    logic [3:0]  AWLEN_S1;
    logic [`AXI_SIZE_BITS-1:0] AWSIZE_S1;
    logic [1:0]                AWBURST_S1;
    logic                      AWVALID_S1;
    logic                      AWREADY_S1;
    // Write Data
    logic [`AXI_DATA_BITS-1:0] WDATA_S1;
    logic [`AXI_STRB_BITS-1:0] WSTRB_S1;
    logic                      WLAST_S1;
    logic                      WVALID_S1;
    logic                      WREADY_S1;
    // Write Response
    logic [`AXI_IDS_BITS-1:0]  BID_S1;
    logic [3:0]                BRESP_S1;
    logic                      BVALID_S1;
    logic                      BREADY_S1;
    // Read Address
    logic [`AXI_IDS_BITS-1:0]  ARID_S1;
    logic [`AXI_ADDR_BITS-1:0] ARADDR_S1;
    logic [3:0]  ARLEN_S1;
    logic [`AXI_SIZE_BITS-1:0] ARSIZE_S1;
    logic [1:0]                ARBURST_S1;
    logic                      ARVALID_S1;
    logic                      ARREADY_S1;
    // Read Data
    logic [`AXI_IDS_BITS-1:0]  RID_S1;
    logic [`AXI_DATA_BITS-1:0] RDATA_S1;
    logic [1:0]                RRESP_S1;
    logic                      RLAST_S1;
    logic                      RVALID_S1;
    logic                      RREADY_S1;

    //AR_channel   IM
    logic [49:0]                     arWire_S1_CDC;
    logic [49:0]                     arWire_S1_CDC_AXI;
    logic                            ARVALID_S1_CDC;
    logic                            ARREADY_S1_CDC;

    //R_channel    IM
    logic [43:0]                     rWire_S1_CDC;
    logic [49:0]                     rWire_S1_CDC_AXI;
    logic                            RVALID_S1_CDC;
    logic                            RREADY_S1_CDC;

    //AW_channel   IM
    logic [49:0]                     awWire_S1_CDC;
    logic [49:0]                     awWire_S1_CDC_AXI;
    logic                            AWVALID_S1_CDC;
    logic                            AWREADY_S1_CDC;

    //W_channel    IM
    logic [37:0]                     wWire_S1_CDC;
    logic [49:0]                     wWire_S1_CDC_AXI;
    logic                            WVALID_S1_CDC;
    logic                            WREADY_S1_CDC;

    //B_channel    IM
    logic [12:0]                     bWire_S1_CDC;
    logic [49:0]                     bWire_S1_CDC_AXI;
    logic                            BVALID_S1_CDC;
    logic                            BREADY_S1_CDC;

    // ================== AXI Slave2 (DM) ==================
    // Write Address
    logic [`AXI_IDS_BITS-1:0]     AWID_S2;
    logic [`AXI_ADDR_BITS-1:0]  AWADDR_S2;
    logic [3:0]    AWLEN_S2;
    logic [`AXI_SIZE_BITS-1:0]  AWSIZE_S2;
    logic [1:0]                AWBURST_S2;
    logic                      AWVALID_S2;
    logic                      AWREADY_S2;
    // Write Data
    logic [`AXI_DATA_BITS-1:0]  WDATA_S2;
    logic [`AXI_STRB_BITS-1:0]  WSTRB_S2;
    logic                       WLAST_S2;
    logic                      WVALID_S2;
    logic                      WREADY_S2;
    // Write Response
    logic [`AXI_IDS_BITS-1:0]     BID_S2;
    logic [3:0]                 BRESP_S2;
    logic                      BVALID_S2;
    logic                      BREADY_S2;
    // Read Address
    logic [`AXI_IDS_BITS-1:0]     ARID_S2;
    logic [`AXI_ADDR_BITS-1:0]  ARADDR_S2;
    logic [3:0]    ARLEN_S2;
    logic [`AXI_SIZE_BITS-1:0]  ARSIZE_S2;
    logic [1:0]                ARBURST_S2;
    logic                      ARVALID_S2;
    logic                      ARREADY_S2;
    // Read Data
    logic [`AXI_IDS_BITS-1:0]      RID_S2;
    logic [`AXI_DATA_BITS-1:0]   RDATA_S2;
    logic [1:0]                  RRESP_S2;
    logic                        RLAST_S2;
    logic                       RVALID_S2;
    logic                       RREADY_S2;

    //AR_channel   DM
    logic [49:0]                     arWire_S2_CDC;
    logic [49:0]                     arWire_S2_CDC_AXI;
    logic                            ARVALID_S2_CDC;
    logic                            ARREADY_S2_CDC;

    //R_channel    DM
    logic [43:0]                     rWire_S2_CDC;
    logic [49:0]                     rWire_S2_CDC_AXI;
    logic                            RVALID_S2_CDC;
    logic                            RREADY_S2_CDC;             

    //AW_channel   DM
    logic [49:0]                     awWire_S2_CDC;
    logic [49:0]                     awWire_S2_CDC_AXI;
    logic                            AWVALID_S2_CDC;
    logic                            AWREADY_S2_CDC;

    //W_channel    DM
    logic [37:0]                     wWire_S2_CDC;
    logic [49:0]                     wWire_S2_CDC_AXI;
    logic                            WVALID_S2_CDC;
    logic                            WREADY_S2_CDC;

    //B_channel    DM
    logic [12:0]                     bWire_S2_CDC;
    logic [49:0]                     bWire_S2_CDC_AXI;
    logic                            BVALID_S2_CDC;
    logic                            BREADY_S2_CDC;

    // ================== AXI Slave3 (DMA) ==================
    // Write Address
    logic [`AXI_IDS_BITS-1:0]     AWID_S3;
    logic [`AXI_ADDR_BITS-1:0]  AWADDR_S3;
    logic [3:0]    AWLEN_S3;
    logic [`AXI_SIZE_BITS-1:0]  AWSIZE_S3;
    logic [1:0]                AWBURST_S3;
    logic                      AWVALID_S3;
    logic                      AWREADY_S3;
    // Write Data
    logic [`AXI_DATA_BITS-1:0]  WDATA_S3;
    logic [`AXI_STRB_BITS-1:0]  WSTRB_S3;
    logic                       WLAST_S3;
    logic                      WVALID_S3;
    logic                      WREADY_S3;
    // Write Response
    logic [`AXI_IDS_BITS-1:0]     BID_S3;
    logic [1:0]                 BRESP_S3;
    logic                      BVALID_S3;
    logic                      BREADY_S3;
    // Read Address
    logic [`AXI_IDS_BITS-1:0]     ARID_S3;
    logic [`AXI_ADDR_BITS-1:0]  ARADDR_S3;
    logic [3:0]    ARLEN_S3;
    logic [`AXI_SIZE_BITS-1:0]  ARSIZE_S3;
    logic [1:0]                ARBURST_S3;
    logic                      ARVALID_S3;
    logic                      ARREADY_S3;
    // Read Data
    logic [`AXI_IDS_BITS-1:0]      RID_S3;
    logic [`AXI_DATA_BITS-1:0]   RDATA_S3;
    logic [3:0]                  RRESP_S3;
    logic                        RLAST_S3;
    logic                       RVALID_S3;
    logic                       RREADY_S3;

    //AW_channel   DMA  (Slave)
    logic [49:0]                     awWire_S3_CDC;
    logic [49:0]                     awWire_S3_CDC_AXI;
    logic                            AWVALID_S3_CDC;
    logic                            AWREADY_S3_CDC;
    //W_channel    DMA  (Slave)
    logic [37:0]                     wWire_S3_CDC;
    logic [49:0]                     wWire_S3_CDC_AXI;
    logic                            WVALID_S3_CDC;
    logic                            WREADY_S3_CDC;
    //B_channel     DMA  (Slave)
    logic [10:0]                     bWire_S3_CDC;
    logic [49:0]                     bWire_S3_CDC_AXI;
    logic                            BVALID_S3_CDC;
    logic                            BREADY_S3_CDC;

        // ================== AXI Slave4 (WDT) ==================
    // Write Address
    logic [`AXI_IDS_BITS-1:0]     AWID_S4;
    logic [`AXI_ADDR_BITS-1:0]  AWADDR_S4;
    logic [3:0]    AWLEN_S4;
    logic [`AXI_SIZE_BITS-1:0]  AWSIZE_S4;
    logic [1:0]                AWBURST_S4;
    logic                      AWVALID_S4;
    logic                      AWREADY_S4;
    // Write Data
    logic [`AXI_DATA_BITS-1:0]  WDATA_S4;
    logic [`AXI_STRB_BITS-1:0]  WSTRB_S4;
    logic                       WLAST_S4;
    logic                      WVALID_S4;
    logic                      WREADY_S4;
    // Write Response
    logic [`AXI_IDS_BITS-1:0]     BID_S4;
    logic [3:0]                 BRESP_S4;
    logic                      BVALID_S4;
    logic                      BREADY_S4;
    // Read Address
    logic [`AXI_IDS_BITS-1:0]     ARID_S4;
    logic [`AXI_ADDR_BITS-1:0]  ARADDR_S4;
    logic [3:0]    ARLEN_S4;
    logic [`AXI_SIZE_BITS-1:0]  ARSIZE_S4;
    logic [1:0]                ARBURST_S4;
    logic                      ARVALID_S4;
    logic                      ARREADY_S4;
    // Read Data
    logic [`AXI_IDS_BITS-1:0]      RID_S4;
    logic [`AXI_DATA_BITS-1:0]   RDATA_S4;
    logic [3:0]                  RRESP_S4;
    logic                        RLAST_S4;
    logic                       RVALID_S4;
    logic                       RREADY_S4;

    //AW_channel   WDT
    logic [49:0]                     awWire_S4_CDC;
    logic [49:0]                     awWire_S4_CDC_AXI;
    logic                            AWVALID_S4_CDC;
    logic                            AWREADY_S4_CDC;
    //W_channel    WDT
    logic [37:0]                     wWire_S4_CDC;
    logic [49:0]                     wWire_S4_CDC_AXI;
    logic                            WVALID_S4_CDC;
    logic                            WREADY_S4_CDC;

    //B_channel    WDT
    logic [12:0]                     bWire_S4_CDC;
    logic [49:0]                     bWire_S4_CDC_AXI;
    logic                            BVALID_S4_CDC;
    logic                            BREADY_S4_CDC;

        // ================== AXI Slave5 (DRAM) ==================
    // Write Address
    logic [`AXI_IDS_BITS-1:0]     AWID_S5;
    logic [`AXI_ADDR_BITS-1:0]  AWADDR_S5;
    logic [3:0]    AWLEN_S5;
    logic [`AXI_SIZE_BITS-1:0]  AWSIZE_S5;
    logic [1:0]                AWBURST_S5;
    logic                      AWVALID_S5;
    logic                      AWREADY_S5;
    // Write Data
    logic [`AXI_DATA_BITS-1:0]  WDATA_S5;
    logic [`AXI_STRB_BITS-1:0]  WSTRB_S5;
    logic                       WLAST_S5;
    logic                      WVALID_S5;
    logic                      WREADY_S5;
    // Write Response
    logic [`AXI_IDS_BITS-1:0]     BID_S5;
    logic [1:0]                 BRESP_S5;
    logic                      BVALID_S5;
    logic                      BREADY_S5;
    // Read Address
    logic [`AXI_IDS_BITS-1:0]     ARID_S5;
    logic [`AXI_ADDR_BITS-1:0]  ARADDR_S5;
    logic [3:0]    ARLEN_S5;
    logic [`AXI_SIZE_BITS-1:0]  ARSIZE_S5;
    logic [1:0]                ARBURST_S5;
    logic                      ARVALID_S5;
    logic                      ARREADY_S5;
    // Read Data
    logic [`AXI_IDS_BITS-1:0]      RID_S5;
    logic [`AXI_DATA_BITS-1:0]   RDATA_S5;
    logic [1:0]                  RRESP_S5;
    logic                        RLAST_S5;
    logic                       RVALID_S5;
    logic                       RREADY_S5;

    //AR_channel   DRAM
    logic [49:0]                     arWire_S5_CDC;
    logic [49:0]                     arWire_S5_CDC_AXI;
    logic                            ARVALID_S5_CDC;
    logic                            ARREADY_S5_CDC;
    //R_channel    DRAM
    logic [43:0]                     rWire_S5_CDC;
    logic [49:0]                     rWire_S5_CDC_AXI;
    logic                            RVALID_S5_CDC;
    logic                            RREADY_S5_CDC;
    
    //AW_channel   DRAM
    logic [49:0]                     awWire_S5_CDC;
    logic [49:0]                     awWire_S5_CDC_AXI;
    logic                            AWVALID_S5_CDC;
    logic                            AWREADY_S5_CDC;

    //W_channel    DRAM
    logic [37:0]                     wWire_S5_CDC;
    logic [49:0]                     wWire_S5_CDC_AXI;
    logic                            WVALID_S5_CDC;
    logic                            WREADY_S5_CDC;

    //B_channel    DRAM
    logic [10:0]                     bWire_S5_CDC;
    logic [49:0]                     bWire_S5_CDC_AXI;
    logic                            BVALID_S5_CDC;
    logic                            BREADY_S5_CDC;

// ================== AXI Slave6 (EPU) ==================
    // Write Address
    logic [`AXI_IDS_BITS-1:0]  AWID_S6;
    logic [`AXI_ADDR_BITS-1:0] AWADDR_S6;
    logic [3:0]                AWLEN_S6;
    logic [`AXI_SIZE_BITS-1:0] AWSIZE_S6;
    logic [1:0]                AWBURST_S6;
    logic                      AWVALID_S6;
    logic                      AWREADY_S6;
    // Write Data
    logic [`AXI_DATA_BITS-1:0] WDATA_S6;
    logic [`AXI_STRB_BITS-1:0] WSTRB_S6;
    logic                      WLAST_S6;
    logic                      WVALID_S6;
    logic                      WREADY_S6;
    // Write Response
    logic [`AXI_IDS_BITS-1:0]  BID_S6;
    logic [1:0]                BRESP_S6;
    logic                      BVALID_S6;
    logic                      BREADY_S6;
    // Read Address
    logic [`AXI_IDS_BITS-1:0]  ARID_S6;
    logic [`AXI_ADDR_BITS-1:0] ARADDR_S6;
    logic [3:0]                ARLEN_S6;
    logic [`AXI_SIZE_BITS-1:0] ARSIZE_S6;
    logic [1:0]                ARBURST_S6;
    logic                      ARVALID_S6;
    logic                      ARREADY_S6;
    // Read Data
    logic [`AXI_IDS_BITS-1:0]  RID_S6;
    logic [`AXI_DATA_BITS-1:0] RDATA_S6;
    logic [1:0]                RRESP_S6;
    logic                      RLAST_S6;
    logic                      RVALID_S6;
    logic                      RREADY_S6;


    assign BID_S4[7:4] = 4'd0;

    // ================== CPU + AXI Masters ==================
    CPU_wrapper CPU_wrapper (
        .ACLK(cpu_clk),
        .rst(cpu_rst),
        .interrupt(interrupt_CDC),
        .WTO(WTO_CDC),
        // M0 (Instruction)
        .ARID_M0(ARID_M0),
        .ARADDR_M0(ARADDR_M0),
        .ARLEN_M0(ARLEN_M0),
        .ARSIZE_M0(ARSIZE_M0),
        .ARBURST_M0(ARBURST_M0),
        .ARVALID_M0(ARVALID_M0),
        .ARREADY_M0(ARREADY_M0),
        .RID_M0(rWire_M0_CDC_AXI[39:36]),
        .RDATA_M0(rWire_M0_CDC_AXI[35:4]),
        .RRESP_M0(rWire_M0_CDC_AXI[3:2]),
        .RLAST_M0(rWire_M0_CDC_AXI[1]),
        .RVALID_M0(RVALID_M0),
        .RREADY_M0(RREADY_M0),
        // M1 (Data)
        .ARID_M1(ARID_M1),
        .ARADDR_M1(ARADDR_M1),
        .ARLEN_M1(ARLEN_M1),
        .ARSIZE_M1(ARSIZE_M1),
        .ARBURST_M1(ARBURST_M1),
        .ARVALID_M1(ARVALID_M1),
        .ARREADY_M1(ARREADY_M1),
        .RID_M1(rWire_M1_CDC_AXI[39:36]),
        .RDATA_M1(rWire_M1_CDC_AXI[35:4]),
        .RRESP_M1(rWire_M1_CDC_AXI[3:2]),
        .RLAST_M1(rWire_M1_CDC_AXI[1]),
        .RVALID_M1(RVALID_M1),
        .RREADY_M1(RREADY_M1),
        .AWID_M1(AWID_M1),
        .AWADDR_M1(AWADDR_M1),
        .AWLEN_M1(AWLEN_M1),
        .AWSIZE_M1(AWSIZE_M1),
        .AWBURST_M1(AWBURST_M1),
        .AWVALID_M1(AWVALID_M1),
        .AWREADY_M1(AWREADY_M1),
        .WDATA_M1(WDATA_M1),
        .WSTRB_M1(WSTRB_M1),
        .WLAST_M1(WLAST_M1),
        .WVALID_M1(WVALID_M1),
        .WREADY_M1(WREADY_M1),
        .BID_M1(bWire_M1_CDC_AXI[8:5]),
        .BRESP_M1(bWire_M1_CDC_AXI[2:1]),
        .BVALID_M1(BVALID_M1),
        .BREADY_M1(BREADY_M1)
    );

    assign arWire_M0_CDC = {ARID_M0,ARADDR_M0,ARLEN_M0,ARSIZE_M0,ARBURST_M0,ARVALID_M0};
    async_CDC_1 cpu_wrapper_m0_ar(
        .clk(cpu_clk),   //WRITE
        .rst(cpu_rst),
        .clk2(axi_clk),  //READ
        .rst2(axi_rst),
        .w_data({4'd0,arWire_M0_CDC}),
        .WEB(!ARVALID_M0),           //cpu_wrapper發出來的(控制指標)
        .I_am_ready(ARREADY_M0_CDC), //axi給的(控制指標)

        .ready(ARREADY_M0),          //給cpu_wrapper的
        .valid(ARVALID_M0_CDC),      //給axi的
        .DO(arWire_M0_CDC_AXI)
    ); 



  assign rWire_M0_CDC = {RID_M0,RDATA_M0,RRESP_M0,RLAST_M0,RVALID_M0_CDC};
  async_CDC_4 cpu_wrapper_m0_r(
      .clk(axi_clk),   //WRITE
      .rst(axi_rst),
      .clk2(cpu_clk),  //READ
      .rst2(cpu_rst),
      .w_data( {10'd0,rWire_M0_CDC} ),
      .WEB(!RVALID_M0_CDC),
      .I_am_ready(RREADY_M0),

      .ready(RREADY_M0_CDC),
      .valid(RVALID_M0),
      .DO(rWire_M0_CDC_AXI)
  ); 



  assign arWire_M1_CDC = {ARID_M1,ARADDR_M1,ARLEN_M1,ARSIZE_M1,ARBURST_M1,ARVALID_M1};
  async_CDC_1 cpu_wrapper_m1_ar(
      .clk(cpu_clk),   //WRITE
      .rst(cpu_rst),
      .clk2(axi_clk),  //READ
      .rst2(axi_rst),
      .w_data( {4'd0,arWire_M1_CDC} ),
      .WEB(!ARVALID_M1),
      .I_am_ready(ARREADY_M1_CDC),
      .ready(ARREADY_M1),
      .valid(ARVALID_M1_CDC),
      .DO(arWire_M1_CDC_AXI)
  ); 


  assign rWire_M1_CDC = {RID_M1,RDATA_M1,RRESP_M1,RLAST_M1,RVALID_M1_CDC};
  async_CDC_4 cpu_wrapper_m1_r(
      .clk(axi_clk),   //WRITE
      .rst(axi_rst),
      .clk2(cpu_clk),  //READ
      .rst2(cpu_rst),
      .w_data({10'd0,rWire_M1_CDC}),
      .WEB(!RVALID_M1_CDC),
      .I_am_ready(RREADY_M1),
      .ready(RREADY_M1_CDC),
      .valid(RVALID_M1),
      .DO(rWire_M1_CDC_AXI)
  ); 


  assign awWire_M1_CDC = {AWID_M1,AWADDR_M1,AWLEN_M1,AWSIZE_M1,AWBURST_M1,AWVALID_M1};
  async_CDC_1 cpu_wrapper_m1_aw(
      .clk(cpu_clk),   //WRITE
      .rst(cpu_rst),
      .clk2(axi_clk),  //READ
      .rst2(axi_rst),
      .w_data({4'd0,awWire_M1_CDC}),
      .WEB(!AWVALID_M1),
      .I_am_ready(AWREADY_M1_CDC),
      .ready(AWREADY_M1),
      .valid(AWVALID_M1_CDC),
      .DO(awWire_M1_CDC_AXI)
  ); 


  assign wWire_M1_CDC = {WDATA_M1,WSTRB_M1,WLAST_M1,WVALID_M1};
  async_CDC_1 cpu_wrapper_m1_w(
      .clk(cpu_clk),   //WRITE
      .rst(cpu_rst),
      .clk2(axi_clk),  //READ
      .rst2(axi_rst),
      .w_data({12'd0,wWire_M1_CDC}),
      .WEB(!WVALID_M1),
      .I_am_ready(WREADY_M1_CDC),
      .ready(WREADY_M1),
      .valid(WVALID_M1_CDC),
      .DO(wWire_M1_CDC_AXI)
  ); 


  assign bWire_M1_CDC = {BID_M1,2'd0,BRESP_M1,BVALID_M1_CDC};
  async_CDC_1 cpu_wrapper_m1_b(
      .clk(axi_clk),   //WRITE
      .rst(axi_rst),
      .clk2(cpu_clk),  //READ
      .rst2(cpu_rst),
      .w_data({41'd0,bWire_M1_CDC}),
      .WEB(!BVALID_M1_CDC),
      .I_am_ready(BREADY_M1),
      .ready(BREADY_M1_CDC),
      .valid(BVALID_M1),
      .DO(bWire_M1_CDC_AXI)
  ); 

    // ================== AXI Interconnect ==================
    AXI AXI (
    .ACLK       (axi_clk),
    .ARESETn    (~axi_rst),

    // MASTER INTERFACE

    //READ
    .ARID_M0(arWire_M0_CDC_AXI[45:42]),
    .ARADDR_M0(arWire_M0_CDC_AXI[41:10]),
    .ARLEN_M0(arWire_M0_CDC_AXI[9:6]),
    .ARSIZE_M0(arWire_M0_CDC_AXI[5:3]),
    .ARBURST_M0(arWire_M0_CDC_AXI[2:1]),
    .ARVALID_M0(ARVALID_M0_CDC),
    .ARREADY_M0(ARREADY_M0_CDC),
    .RID_M0(RID_M0),
    .RDATA_M0(RDATA_M0),
    .RRESP_M0(RRESP_M0),
    .RLAST_M0(RLAST_M0),
    .RVALID_M0(RVALID_M0_CDC),
    .RREADY_M0(RREADY_M0_CDC),

    //READ
    .ARID_M1(arWire_M1_CDC_AXI[45:42]),
    .ARADDR_M1(arWire_M1_CDC_AXI[41:10]),
    .ARLEN_M1(arWire_M1_CDC_AXI[9:6]),
    .ARSIZE_M1(arWire_M1_CDC_AXI[5:3]),
    .ARBURST_M1(arWire_M1_CDC_AXI[2:1]),
    .ARVALID_M1(ARVALID_M1_CDC),
    .ARREADY_M1(ARREADY_M1_CDC),
    .RID_M1(RID_M1),
    .RDATA_M1(RDATA_M1),
    .RRESP_M1(RRESP_M1),
    .RLAST_M1(RLAST_M1),
    .RVALID_M1(RVALID_M1_CDC),
    .RREADY_M1(RREADY_M1_CDC),

    //WRITE
    .AWID_M1(awWire_M1_CDC_AXI[45:42]),
    .AWADDR_M1(awWire_M1_CDC_AXI[41:10]),
    .AWLEN_M1(awWire_M1_CDC_AXI[9:6]),
    .AWSIZE_M1(awWire_M1_CDC_AXI[5:3]),
    .AWBURST_M1(awWire_M1_CDC_AXI[2:1]),
    .AWVALID_M1(AWVALID_M1_CDC),
    .AWREADY_M1(AWREADY_M1_CDC),
    .WDATA_M1(wWire_M1_CDC_AXI[37:6]),
    .WSTRB_M1(wWire_M1_CDC_AXI[5:2]),
    .WLAST_M1(wWire_M1_CDC_AXI[1]),
    .WVALID_M1(WVALID_M1_CDC),
    .WREADY_M1(WREADY_M1_CDC),
    .BID_M1(BID_M1),
    .BRESP_M1(BRESP_M1),
    .BVALID_M1(BVALID_M1_CDC),
    .BREADY_M1(BREADY_M1_CDC),
    
    .ARID_M2    (arWire_M2_CDC_AXI[45:42]),
    .ARADDR_M2  (arWire_M2_CDC_AXI[41:10]),
    .ARLEN_M2   (arWire_M2_CDC_AXI[9:6]),
    .ARSIZE_M2  (arWire_M2_CDC_AXI[5:3]),
    .ARBURST_M2 (arWire_M2_CDC_AXI[2:1]),
    .ARVALID_M2 (ARVALID_M2_CDC),
    .ARREADY_M2 (ARREADY_M2_CDC),
    .RID_M2     (RID_M2),
    .RDATA_M2   (RDATA_M2),
    .RRESP_M2   (RRESP_M2[1:0]),
    .RLAST_M2   (RLAST_M2),
    .RVALID_M2  (RVALID_M2_CDC),
    .RREADY_M2  (RREADY_M2_CDC),

    .AWID_M2    (awWire_M2_CDC_AXI[45:42]),
    .AWADDR_M2  (awWire_M2_CDC_AXI[41:10]),
    .AWLEN_M2   (awWire_M2_CDC_AXI[9:6]),
    .AWSIZE_M2  (awWire_M2_CDC_AXI[5:3]),
    .AWBURST_M2 (awWire_M2_CDC_AXI[2:1]),
    .AWVALID_M2 (AWVALID_M2_CDC),
    .AWREADY_M2 (AWREADY_M2_CDC),
    .WDATA_M2   (wWire_M2_CDC_AXI[37:6]),
    .WSTRB_M2   (wWire_M2_CDC_AXI[5:2]),
    .WLAST_M2   (wWire_M2_CDC_AXI[1]),
    .WVALID_M2  (WVALID_M2_CDC),
    .WREADY_M2  (WREADY_M2_CDC),
    .BID_M2     (BID_M2),
    .BRESP_M2   (BRESP_M2[1:0]),
    .BVALID_M2  (BVALID_M2_CDC),
    .BREADY_M2  (BREADY_M2_CDC),

    // SLAVE INTERFACE
    // S0 (Read 0 - ROM)
    .ARID_S0    (ARID_S0),
    .ARADDR_S0  (ARADDR_S0),
    .ARLEN_S0   (ARLEN_S0),
    .ARSIZE_S0  (ARSIZE_S0),
    .ARBURST_S0 (ARBURST_S0),
    .ARVALID_S0 (ARVALID_S0_CDC),
    .ARREADY_S0 (ARREADY_S0_CDC),
    .RID_S0     (rWire_S0_CDC_AXI[43:36]),
    .RDATA_S0   (rWire_S0_CDC_AXI[35:4]),
    //.RRESP_S0   (RRESP_S0[1:0]),
    .RRESP_S0   (rWire_S0_CDC_AXI[3:2]),
    .RLAST_S0   (rWire_S0_CDC_AXI[1]),
    .RVALID_S0  (RVALID_S0_CDC),
    .RREADY_S0  (RREADY_S0_CDC),

    // S1 (Write 1 - IM)
    .AWID_S1    (AWID_S1),
    .AWADDR_S1  (AWADDR_S1),
    .AWLEN_S1   (AWLEN_S1),
    .AWSIZE_S1  (AWSIZE_S1),
    .AWBURST_S1 (AWBURST_S1),
    .AWVALID_S1 (AWVALID_S1_CDC),
    .AWREADY_S1 (AWREADY_S1_CDC),
    .WDATA_S1   (WDATA_S1),
    .WSTRB_S1   (WSTRB_S1),
    .WLAST_S1   (WLAST_S1),
    .WVALID_S1  (WVALID_S1_CDC),
    .WREADY_S1  (WREADY_S1_CDC),
    .BID_S1     (bWire_S1_CDC_AXI[12:5]),
    //.BRESP_S1   (BRESP_S1[1:0]),
    .BRESP_S1   (bWire_S1_CDC_AXI[2:1]),
    .BVALID_S1  (BVALID_S1_CDC),
    .BREADY_S1  (BREADY_S1_CDC),

    .ARID_S1    (ARID_S1),
    .ARADDR_S1  (ARADDR_S1),
    .ARLEN_S1   (ARLEN_S1),
    .ARSIZE_S1  (ARSIZE_S1),
    .ARBURST_S1 (ARBURST_S1),
    .ARVALID_S1 (ARVALID_S1_CDC),
    .ARREADY_S1 (ARREADY_S1_CDC),
    .RID_S1     (rWire_S1_CDC_AXI[43:36]),
    .RDATA_S1   (rWire_S1_CDC_AXI[35:4]),
    //.RRESP_S1   (RRESP_S1[1:0]),
    .RRESP_S1   (rWire_S1_CDC_AXI[3:2]),
    .RLAST_S1   (rWire_S1_CDC_AXI[1]),
    .RVALID_S1  (RVALID_S1_CDC),
    .RREADY_S1  (RREADY_S1_CDC),

    // S2 (Write 2 - DM)
    .AWID_S2    (AWID_S2),
    .AWADDR_S2  (AWADDR_S2),
    .AWLEN_S2   (AWLEN_S2),
    .AWSIZE_S2  (AWSIZE_S2),
    .AWBURST_S2 (AWBURST_S2),
    .AWVALID_S2 (AWVALID_S2_CDC),
    .AWREADY_S2 (AWREADY_S2_CDC),
    .WDATA_S2   (WDATA_S2),
    .WSTRB_S2   (WSTRB_S2),
    .WLAST_S2   (WLAST_S2),
    .WVALID_S2  (WVALID_S2_CDC),
    .WREADY_S2  (WREADY_S2_CDC),
    .BID_S2     (bWire_S2_CDC_AXI[12:5]),
    //.BRESP_S2   (BRESP_S2[1:0]),
    .BRESP_S2   (bWire_S2_CDC_AXI[2:1]),
    .BVALID_S2  (BVALID_S2_CDC),
    .BREADY_S2  (BREADY_S2_CDC),
    .ARID_S2    (ARID_S2),
    .ARADDR_S2  (ARADDR_S2),
    .ARLEN_S2   (ARLEN_S2),
    .ARSIZE_S2  (ARSIZE_S2),
    .ARBURST_S2 (ARBURST_S2),
    .ARVALID_S2 (ARVALID_S2_CDC),
    .ARREADY_S2 (ARREADY_S2_CDC),
    .RID_S2     (rWire_S2_CDC_AXI[43:36]),
    .RDATA_S2   (rWire_S2_CDC_AXI[35:4]),
    //.RRESP_S2   (RRESP_S2[1:0]),
    .RRESP_S2   (rWire_S2_CDC_AXI[3:2]),
    .RLAST_S2   (rWire_S2_CDC_AXI[1]),
    .RVALID_S2  (RVALID_S2_CDC),
    .RREADY_S2  (RREADY_S2_CDC),

    // S3 (Write 3 - DMA)
    .AWID_S3    (AWID_S3),
    .AWADDR_S3  (AWADDR_S3),
    .AWLEN_S3   (AWLEN_S3),
    .AWSIZE_S3  (AWSIZE_S3),
    .AWBURST_S3 (AWBURST_S3),
    .AWVALID_S3 (AWVALID_S3_CDC),
    .AWREADY_S3 (AWREADY_S3_CDC),
    .WDATA_S3   (WDATA_S3),
    .WSTRB_S3   (WSTRB_S3),
    .WLAST_S3   (WLAST_S3),
    .WVALID_S3  (WVALID_S3_CDC),
    .WREADY_S3  (WREADY_S3_CDC),
    .BID_S3     (bWire_S3_CDC_AXI[10:3]),
    //.BRESP_S3   (BRESP_S3[1:0]),
    .BRESP_S3   (bWire_S3_CDC_AXI[2:1]),
    .BVALID_S3  (BVALID_S3_CDC),
    .BREADY_S3  (BREADY_S3_CDC),

    // S4 (Write 4 - WDT)
    .AWID_S4    (AWID_S4),
    .AWADDR_S4  (AWADDR_S4),
    .AWLEN_S4   (AWLEN_S4),
    .AWSIZE_S4  (AWSIZE_S4),
    .AWBURST_S4 (AWBURST_S4),
    .AWVALID_S4 (AWVALID_S4_CDC),
    .AWREADY_S4 (AWREADY_S4_CDC),
    .WDATA_S4   (WDATA_S4),
    .WSTRB_S4   (WSTRB_S4),
    .WLAST_S4   (WLAST_S4),
    .WVALID_S4  (WVALID_S4_CDC),
    .WREADY_S4  (WREADY_S4_CDC),
    .BID_S4     (bWire_S4_CDC_AXI[12:5]),
    //.BRESP_S4   (BRESP_S4[1:0]),
    .BRESP_S4   (bWire_S4_CDC_AXI[2:1]),
    .BVALID_S4  (BVALID_S4_CDC),
    .BREADY_S4  (BREADY_S4_CDC),

    // S5 (Write/Read 5 - DRAM)
    .AWID_S5    (AWID_S5),
    .AWADDR_S5  (AWADDR_S5),
    .AWLEN_S5   (AWLEN_S5),
    .AWSIZE_S5  (AWSIZE_S5),
    .AWBURST_S5 (AWBURST_S5),
    .AWVALID_S5 (AWVALID_S5_CDC),
    .AWREADY_S5 (AWREADY_S5_CDC),
    .WDATA_S5   (WDATA_S5),
    .WSTRB_S5   (WSTRB_S5),
    .WLAST_S5   (WLAST_S5),
    .WVALID_S5  (WVALID_S5_CDC),
    .WREADY_S5  (WREADY_S5_CDC),
    .BID_S5     (bWire_S5_CDC_AXI[10:3]),
    //.BRESP_S5   (BRESP_S5[1:0]),
    .BRESP_S5   (bWire_S5_CDC_AXI[2:1]),/////////////////////////////////////////////////////////////////////////
    .BVALID_S5  (BVALID_S5_CDC),
    .BREADY_S5  (BREADY_S5_CDC),
    .ARID_S5    (ARID_S5),
    .ARADDR_S5  (ARADDR_S5),
    .ARLEN_S5   (ARLEN_S5),
    .ARSIZE_S5  (ARSIZE_S5),
    .ARBURST_S5 (ARBURST_S5),
    .ARVALID_S5 (ARVALID_S5_CDC),
    .ARREADY_S5 (ARREADY_S5_CDC),
    .RID_S5     (rWire_S5_CDC_AXI[43:36]),
    .RDATA_S5   (rWire_S5_CDC_AXI[35:4]),
    //.RRESP_S5   (RRESP_S5[1:0]),
    .RRESP_S5   (rWire_S5_CDC_AXI[3:2]),
    .RLAST_S5   (rWire_S5_CDC_AXI[1]),
    .RVALID_S5  (RVALID_S5_CDC),
    .RREADY_S5  (RREADY_S5_CDC),

    // S6 (Write/Read 6 - EPU)
    // Write Address Channel
    .AWID_S6    (AWID_S6),
    .AWADDR_S6  (AWADDR_S6),
    .AWLEN_S6   (AWLEN_S6),
    .AWSIZE_S6  (AWSIZE_S6),
    .AWBURST_S6 (AWBURST_S6),
    .AWVALID_S6 (AWVALID_S6),
    .AWREADY_S6 (AWREADY_S6),

    // Write Data Channel
    .WDATA_S6   (WDATA_S6),
    .WSTRB_S6   (WSTRB_S6),
    .WLAST_S6   (WLAST_S6),
    .WVALID_S6  (WVALID_S6),
    .WREADY_S6  (WREADY_S6),

    // Write Response Channel
    .BID_S6     (BID_S6),
    .BRESP_S6   (BRESP_S6),
    .BVALID_S6  (BVALID_S6),
    .BREADY_S6  (BREADY_S6),

    // Read Address Channel
    .ARID_S6    (ARID_S6),
    .ARADDR_S6  (ARADDR_S6),
    .ARLEN_S6   (ARLEN_S6),
    .ARSIZE_S6  (ARSIZE_S6),
    .ARBURST_S6 (ARBURST_S6),
    .ARVALID_S6 (ARVALID_S6),
    .ARREADY_S6 (ARREADY_S6),

    // Read Data Channel
    .RID_S6     (RID_S6),
    .RDATA_S6   (RDATA_S6),
    .RRESP_S6   (RRESP_S6),
    .RLAST_S6   (RLAST_S6),
    .RVALID_S6  (RVALID_S6),
    .RREADY_S6  (RREADY_S6)
);

// ================== Instruction ROM (Slave 0) ==================
    ROM_wrapper ROM1 (
        .ACLK(rom_clk),
        .ARESETn(~rom_rst),
        .ARID_S(arWire_S0_CDC_AXI[45:42]),
        .ARADDR_S(arWire_S0_CDC_AXI[41:10]),
        .ARLEN_S(arWire_S0_CDC_AXI[9:6]),
        .ARSIZE_S(arWire_S0_CDC_AXI[5:3]),
        .ARBURST_S(arWire_S0_CDC_AXI[2:1]),
        .ARVALID_S(ARVALID_S0),
        .ARREADY_S(ARREADY_S0),
        .RID_S(RID_S0[3:0]),
        .RDATA_S(RDATA_S0),
        .RRESP_S(RRESP_S0),
        .RLAST_S(RLAST_S0),
        .RVALID_S(RVALID_S0),
        .RREADY_S(RREADY_S0),

        //interface
        .OE(ROM_read),
        .CS(ROM_enable),
        .DO(ROM_out),
        .A(ROM_address[11:0])
);

    assign arWire_S0_CDC = {ARID_S0,ARADDR_S0,ARLEN_S0,ARSIZE_S0,ARBURST_S0,ARVALID_S0_CDC};
    async_CDC_1  rom_wrapper_ar(
        .clk(axi_clk),   //WRITE
        .rst(axi_rst),
        .clk2(rom_clk),  //READ
        .rst2(rom_rst),
        .w_data(arWire_S0_CDC),
        .WEB(!ARVALID_S0_CDC),
        .I_am_ready(ARREADY_S0),
        .ready(ARREADY_S0_CDC),
        .valid(ARVALID_S0),
        .DO(arWire_S0_CDC_AXI)
    ); 


    assign rWire_S0_CDC = {4'd0,RID_S0[3:0],RDATA_S0,RRESP_S0,RLAST_S0,RVALID_S0};
    async_CDC_4  rom_wrapper_r(
        .clk(rom_clk),   //WRITE
        .rst(rom_rst),
        .clk2(axi_clk),  //READ
        .rst2(axi_rst),
        .w_data({6'd0,rWire_S0_CDC}),
        .WEB(!RVALID_S0),
        .I_am_ready(RREADY_S0_CDC),
        .ready(RREADY_S0),
        .valid(RVALID_S0_CDC),
        .DO(rWire_S0_CDC_AXI)
    ); 

// ================== Data SRAM (Slave 1) ==================
    SRAM_wrapper IM1 (
        .ACLK(cpu_clk),
        .ARESETn(~cpu_rst),
        //.AWID_S(AWID_S1[3:0]),
        .AWID_S(awWire_S1_CDC_AXI[45:42]),
        .AWADDR_S(awWire_S1_CDC_AXI[41:10]),
        .AWLEN_S(awWire_S1_CDC_AXI[9:6]),
        .AWSIZE_S(awWire_S1_CDC_AXI[5:3]),
        .AWBURST_S(awWire_S1_CDC_AXI[2:1]),
        .AWVALID_S(AWVALID_S1),
        .AWREADY_S(AWREADY_S1),
        .WDATA_S(wWire_S1_CDC_AXI[37:6]),
        .WSTRB_S(wWire_S1_CDC_AXI[5:2]),
        .WLAST_S(wWire_S1_CDC_AXI[1]),
        .WVALID_S(WVALID_S1),
        .WREADY_S(WREADY_S1),
        .BID_S(BID_S1[3:0]),
        .BRESP_S(BRESP_S1),
        .BVALID_S(BVALID_S1),
        .BREADY_S(BREADY_S1),

        //.ARID_S(ARID_S1[3:0]),
        .ARID_S(arWire_S1_CDC_AXI[45:42]),
        .ARADDR_S(arWire_S1_CDC_AXI[41:10]),
        .ARLEN_S(arWire_S1_CDC_AXI[9:6]),
        .ARSIZE_S(arWire_S1_CDC_AXI[5:3]),
        .ARBURST_S(arWire_S1_CDC_AXI[2:1]),
        .ARVALID_S(ARVALID_S1),
        .ARREADY_S(ARREADY_S1),
        .RID_S(RID_S1[3:0]),
        .RDATA_S(RDATA_S1),
        .RRESP_S(RRESP_S1),
        .RLAST_S(RLAST_S1),
        .RVALID_S(RVALID_S1),
        .RREADY_S(RREADY_S1)
    );

    assign arWire_S1_CDC = {ARID_S1,ARADDR_S1,ARLEN_S1,ARSIZE_S1,ARBURST_S1,ARVALID_S1_CDC};
    async_CDC_1  im_wrapper_ar(
        .clk(axi_clk),   //WRITE
        .rst(axi_rst),
        .clk2(cpu_clk),  //READ
        .rst2(cpu_rst),
        .w_data(arWire_S1_CDC),
        .WEB(!ARVALID_S1_CDC),
        .I_am_ready(ARREADY_S1),
        .ready(ARREADY_S1_CDC),
        .valid(ARVALID_S1),
        .DO(arWire_S1_CDC_AXI)
    ); 

    assign rWire_S1_CDC = {4'd0,RID_S1[3:0],RDATA_S1,RRESP_S1,RLAST_S1,RVALID_S1};
    async_CDC_4 im_wrapper_r(
        .clk(cpu_clk),   //WRITE
        .rst(cpu_rst),
        .clk2(axi_clk),  //READ
        .rst2(axi_rst),
        .w_data({6'd0,rWire_S1_CDC}),
        .WEB(!RVALID_S1),
        .I_am_ready(RREADY_S1_CDC),
        .ready(RREADY_S1),
        .valid(RVALID_S1_CDC),
        .DO(rWire_S1_CDC_AXI)
    ); 


    assign awWire_S1_CDC = {AWID_S1,AWADDR_S1,AWLEN_S1,AWSIZE_S1,AWBURST_S1,AWVALID_S1_CDC};
    async_CDC_1  im_wrapper_aw(
        .clk(axi_clk),   //WRITE
        .rst(axi_rst),
        .clk2(cpu_clk),  //READ
        .rst2(cpu_rst),
        .w_data(awWire_S1_CDC),
        .WEB(!AWVALID_S1_CDC),
        .I_am_ready(AWREADY_S1),
        .ready(AWREADY_S1_CDC),
        .valid(AWVALID_S1),
        .DO(awWire_S1_CDC_AXI)
    ); 



    assign wWire_S1_CDC = {WDATA_S1,WSTRB_S1,WLAST_S1,WVALID_S1_CDC};
    async_CDC_16  im_wrapper_w(
        .clk(axi_clk),   //WRITE
        .rst(axi_rst),
        .clk2(cpu_clk),  //READ
        .rst2(cpu_rst),
        .w_data({12'd0,wWire_S1_CDC}),
        .WEB(!WVALID_S1_CDC),
        .I_am_ready(WREADY_S1),
        .ready(WREADY_S1_CDC),
        .valid(WVALID_S1),
        .DO(wWire_S1_CDC_AXI)
    ); 

    assign bWire_S1_CDC = {4'd0,BID_S1[3:0],BRESP_S1,BVALID_S1};
    async_CDC_1 im_wrapper_b(
        .clk(cpu_clk),   //WRITE
        .rst(cpu_rst),
        .clk2(axi_clk),  //READ
        .rst2(axi_rst),
        .w_data({37'd0,bWire_S1_CDC}),
        .WEB(!BVALID_S1),
        .I_am_ready(BREADY_S1_CDC),
        .ready(BREADY_S1),
        .valid(BVALID_S1_CDC),
        .DO(bWire_S1_CDC_AXI)
    ); 

// ================== Data SRAM (Slave 2) ==================
    SRAM_wrapper DM1 (
        .ACLK(cpu_clk),
        .ARESETn(~cpu_rst),
        //.AWID_S(AWID_S2[3:0]),
        .AWID_S(awWire_S2_CDC_AXI[45:42]),
        .AWADDR_S(awWire_S2_CDC_AXI[41:10]),
        .AWLEN_S(awWire_S2_CDC_AXI[9:6]),
        .AWSIZE_S(awWire_S2_CDC_AXI[5:3]),
        .AWBURST_S(awWire_S2_CDC_AXI[2:1]),
        .AWVALID_S(AWVALID_S2),
        .AWREADY_S(AWREADY_S2),
        .WDATA_S(wWire_S2_CDC_AXI[37:6]),
        .WSTRB_S(wWire_S2_CDC_AXI[5:2]),
        .WLAST_S(wWire_S2_CDC_AXI[1]),
        .WVALID_S(WVALID_S2),
        .WREADY_S(WREADY_S2),
        .BID_S(BID_S2[3:0]),
        .BRESP_S(BRESP_S2),
        .BVALID_S(BVALID_S2),
        .BREADY_S(BREADY_S2),

        //.ARID_S(ARID_S2[3:0]),
        .ARID_S(arWire_S2_CDC_AXI[45:42]),
        .ARADDR_S(arWire_S2_CDC_AXI[41:10]),
        .ARLEN_S(arWire_S2_CDC_AXI[9:6]),
        .ARSIZE_S(arWire_S2_CDC_AXI[5:3]),
        .ARBURST_S(arWire_S2_CDC_AXI[2:1]),
        .ARVALID_S(ARVALID_S2),
        .ARREADY_S(ARREADY_S2),
        .RID_S(RID_S2[3:0]),
        .RDATA_S(RDATA_S2),
        .RRESP_S(RRESP_S2),
        .RLAST_S(RLAST_S2),
        .RVALID_S(RVALID_S2),
        .RREADY_S(RREADY_S2)
    );

    assign arWire_S2_CDC = {ARID_S2,ARADDR_S2,ARLEN_S2,ARSIZE_S2,ARBURST_S2,ARVALID_S2_CDC};
    async_CDC_1  dm_wrapper_ar(
        .clk(axi_clk),   //WRITE
        .rst(axi_rst),
        .clk2(cpu_clk),  //READ
        .rst2(cpu_rst),
        .w_data(arWire_S2_CDC),
        .WEB(!ARVALID_S2_CDC),
        .I_am_ready(ARREADY_S2),
        .ready(ARREADY_S2_CDC),
        .valid(ARVALID_S2),
        .DO(arWire_S2_CDC_AXI)
    ); 

    assign rWire_S2_CDC = {4'd0,RID_S2[3:0],RDATA_S2,RRESP_S2,RLAST_S2,RVALID_S2};
    async_CDC_4  dm_wrapper_r(
        .clk(cpu_clk),   //WRITE
        .rst(cpu_rst),
        .clk2(axi_clk),  //READ
        .rst2(axi_rst),
        .w_data({6'd0,rWire_S2_CDC}),
        .WEB(!RVALID_S2),
        .I_am_ready(RREADY_S2_CDC),
        .ready(RREADY_S2),
        .valid(RVALID_S2_CDC),
        .DO(rWire_S2_CDC_AXI)
    ); 

    assign awWire_S2_CDC = {AWID_S2,AWADDR_S2,AWLEN_S2,AWSIZE_S2,AWBURST_S2,AWVALID_S2_CDC};
    async_CDC_1  dm_wrapper_aw(
        .clk(axi_clk),   //WRITE
        .rst(axi_rst),
        .clk2(cpu_clk),  //READ
        .rst2(cpu_rst),
        .w_data(awWire_S2_CDC),
        .WEB(!AWVALID_S2_CDC),
        .I_am_ready(AWREADY_S2),
        .ready(AWREADY_S2_CDC),
        .valid(AWVALID_S2),
        .DO(awWire_S2_CDC_AXI)
    ); 

    assign wWire_S2_CDC = {WDATA_S2,WSTRB_S2,WLAST_S2,WVALID_S2_CDC};
    async_CDC_16  dm_wrapper_w(
        .clk(axi_clk),   //WRITE
        .rst(axi_rst),
        .clk2(cpu_clk),  //READ
        .rst2(cpu_rst),
        .w_data({12'd0,wWire_S2_CDC}),
        .WEB(!WVALID_S2_CDC),
        .I_am_ready(WREADY_S2),
        .ready(WREADY_S2_CDC),
        .valid(WVALID_S2),
        .DO(wWire_S2_CDC_AXI)
    ); 

    assign bWire_S2_CDC = {4'd0,BID_S2[3:0],BRESP_S2,BVALID_S2};
    async_CDC_1 dm_wrapper_b(
        .clk(cpu_clk),   //WRITE
        .rst(cpu_rst),
        .clk2(axi_clk),  //READ
        .rst2(axi_rst),
        .w_data({37'd0,bWire_S2_CDC}),
        .WEB(!BVALID_S2),
        .I_am_ready(BREADY_S2_CDC),
        .ready(BREADY_S2),
        .valid(BVALID_S2_CDC),
        .DO(bWire_S2_CDC_AXI)
    ); 

// ================== Data DMA (Slave 3) ==================
    DMA_wrapper DMA1 (
        //slave interface
        .ACLK(cpu_clk),
        .ARESETn(~cpu_rst),
        //.AWID_S(AWID_S3[3:0]),
        .AWID_S(awWire_S3_CDC_AXI[45:42]),
        .AWADDR_S(awWire_S3_CDC_AXI[41:10]),
        .AWLEN_S(awWire_S3_CDC_AXI[9:6]),
        .AWSIZE_S(awWire_S3_CDC_AXI[5:3]),
        .AWBURST_S(awWire_S3_CDC_AXI[2:1]),
        .AWVALID_S(AWVALID_S3),
        .AWREADY_S(AWREADY_S3),
        .WDATA_S(wWire_S3_CDC_AXI[37:6]),
        .WSTRB_S(wWire_S3_CDC_AXI[5:2]),
        .WLAST_S(wWire_S3_CDC_AXI[1]),
        .WVALID_S(WVALID_S3),
        .WREADY_S(WREADY_S3),
        .BID_S(BID_S3[3:0]),
        .BRESP_S(BRESP_S3),
        .BVALID_S(BVALID_S3),
        .BREADY_S(BREADY_S3),

        //master interface
        .ARID_M(ARID_M2),
        .ARADDR_M(ARADDR_M2),
        .ARLEN_M(ARLEN_M2),
        .ARSIZE_M(ARSIZE_M2),
        .ARBURST_M(ARBURST_M2),
        .ARVALID_M(ARVALID_M2),
        .ARREADY_M(ARREADY_M2),
        .RID_M(rWire_M2_CDC_AXI[39:36]),
        .RDATA_M(rWire_M2_CDC_AXI[35:4]),
        .RRESP_M(rWire_M2_CDC_AXI[3:2]),
        .RLAST_M(rWire_M2_CDC_AXI[1]),
        .RVALID_M(RVALID_M2),
        .RREADY_M(RREADY_M2),
        .AWID_M(AWID_M2),
        .AWADDR_M(AWADDR_M2),
        .AWLEN_M(AWLEN_M2),
        .AWSIZE_M(AWSIZE_M2),
        .AWBURST_M(AWBURST_M2),
        .AWVALID_M(AWVALID_M2),
        .AWREADY_M(AWREADY_M2),
        .WDATA_M(WDATA_M2),
        .WSTRB_M(WSTRB_M2),
        .WLAST_M(WLAST_M2),
        .WVALID_M(WVALID_M2),
        .WREADY_M(WREADY_M2),
        .BID_M(bWire_M2_CDC_AXI[6:3]),
        .BRESP_M(bWire_M2_CDC_AXI[2:1]),
        .BVALID_M(BVALID_M2),
        .BREADY_M(BREADY_M2),

        //interrupt
        .ext_interrupt(interrupt_dma)
    );

//-------------------------  Slave --------------------------------//
    assign awWire_S3_CDC = {AWID_S3,AWADDR_S3,AWLEN_S3,AWSIZE_S3,AWBURST_S3,AWVALID_S3_CDC};
    async_CDC_1  dma_s_wrapper_aw(
        .clk(axi_clk),   //WRITE
        .rst(axi_rst),
        .clk2(cpu_clk),  //READ
        .rst2(cpu_rst),
        .w_data(awWire_S3_CDC),
        .WEB(!AWVALID_S3_CDC),
        .I_am_ready(AWREADY_S3),
        .ready(AWREADY_S3_CDC),
        .valid(AWVALID_S3),
        .DO(awWire_S3_CDC_AXI)
    ); 

    assign wWire_S3_CDC = {WDATA_S3,WSTRB_S3,WLAST_S3,WVALID_S3_CDC};
    async_CDC_1  dma_s_wrapper_w(
        .clk(axi_clk),   //WRITE
        .rst(axi_rst),
        .clk2(cpu_clk),  //READ
        .rst2(cpu_rst),
        .w_data({12'd0,wWire_S3_CDC}),
        .WEB(!WVALID_S3_CDC),
        .I_am_ready(WREADY_S3),
        .ready(WREADY_S3_CDC),
        .valid(WVALID_S3),
        .DO(wWire_S3_CDC_AXI)
    ); 


    assign bWire_S3_CDC = {4'd0,BID_S3[3:0],BRESP_S3,BVALID_S3};
    async_CDC_1 dma_s_wrapper_b(
        .clk(cpu_clk),   //WRITE
        .rst(cpu_rst),
        .clk2(axi_clk),  //READ
        .rst2(axi_rst),
        .w_data({39'd0,bWire_S3_CDC}),
        .WEB(!BVALID_S3),
        .I_am_ready(BREADY_S3_CDC),
        .ready(BREADY_S3),
        .valid(BVALID_S3_CDC),
        .DO(bWire_S3_CDC_AXI)
    ); 

//-------------------------  Master --------------------------------//
    assign arWire_M2_CDC = {ARID_M2,ARADDR_M2,ARLEN_M2,ARSIZE_M2,ARBURST_M2,ARVALID_M2};
    async_CDC_1 dma_m_wrapper_ar(
        .clk(cpu_clk),   //WRITE
        .rst(cpu_rst),
        .clk2(axi_clk),  //READ
        .rst2(axi_rst),
        .w_data({4'd0,arWire_M2_CDC}),
        .WEB(!ARVALID_M2),
        .I_am_ready(ARREADY_M2_CDC),
        .ready(ARREADY_M2),
        .valid(ARVALID_M2_CDC),
        .DO(arWire_M2_CDC_AXI)
    ); 



    assign rWire_M2_CDC = {RID_M2,RDATA_M2,RRESP_M2,RLAST_M2,RVALID_M2_CDC};
    async_CDC_16 dma_m_wrapper_r(
        .clk(axi_clk),   //WRITE
        .rst(axi_rst),
        .clk2(cpu_clk),  //READ
        .rst2(cpu_rst),
        .w_data({10'd0,rWire_M2_CDC}),
        .WEB(!RVALID_M2_CDC),
        .I_am_ready(RREADY_M2),                           //RREADY_M2
        .ready(RREADY_M2_CDC),
        .valid(RVALID_M2),
        .DO(rWire_M2_CDC_AXI)
    ); 



    assign awWire_M2_CDC = {AWID_M2,AWADDR_M2,AWLEN_M2,AWSIZE_M2,AWBURST_M2,AWVALID_M2};
    async_CDC_1 dma_m_wrapper_aw(
        .clk(cpu_clk),   //WRITE
        .rst(cpu_rst),
        .clk2(axi_clk),  //READ
        .rst2(axi_rst),
        .w_data({4'd0,awWire_M2_CDC}),
        .WEB(!AWVALID_M2),
        .I_am_ready(AWREADY_M2_CDC),
        .ready(AWREADY_M2),
        .valid(AWVALID_M2_CDC),
        .DO(awWire_M2_CDC_AXI)
    ); 


    assign wWire_M2_CDC = {WDATA_M2,WSTRB_M2,WLAST_M2,WVALID_M2};
    async_CDC_16  dma_m_wrapper_w(
        .clk(cpu_clk),   //WRITE
        .rst(cpu_rst),
        .clk2(axi_clk),  //READ
        .rst2(axi_rst),
        .w_data({12'd0,wWire_M2_CDC}),
        .WEB(!WVALID_M2),
        .I_am_ready(WREADY_M2_CDC),
        .ready(WREADY_M2),
        .valid(WVALID_M2_CDC),
        .DO(wWire_M2_CDC_AXI)
    ); 



    assign bWire_M2_CDC = {BID_M2,BRESP_M2,BVALID_M2_CDC};
    async_CDC_1 dma_m_wrapper_b(
        .clk(axi_clk),   //WRITE
        .rst(axi_rst),
        .clk2(cpu_clk),  //READ
        .rst2(cpu_rst),
        .w_data({43'd0,bWire_M2_CDC}),
        .WEB(!BVALID_M2_CDC),
        .I_am_ready(BREADY_M2),
        .ready(BREADY_M2_CDC),
        .valid(BVALID_M2),
        .DO(bWire_M2_CDC_AXI)
    ); 
    WDT_wrapper WDT1(
        .ACLK      (rom_clk),
        .rst       (rom_rst),
        .clk2      (cpu_clk),
        .rst2      (cpu_rst),

        // Write Address Channel
        .AWID_S   (awWire_S4_CDC_AXI[45:42]),
        .AWADDR_S (awWire_S4_CDC_AXI[41:10]),
        .AWLEN_S  (awWire_S4_CDC_AXI[9:6]),
        .AWSIZE_S (awWire_S4_CDC_AXI[5:3]),
        .AWBURST_S(awWire_S4_CDC_AXI[2:1]),
        .AWVALID_S (AWVALID_S4),
        .AWREADY_S (AWREADY_S4),

        // Write Data Channel
        .WDATA_S  (wWire_S4_CDC_AXI[37:6]),
        .WSTRB_S  (wWire_S4_CDC_AXI[5:2]),
        .WLAST_S  (wWire_S4_CDC_AXI[1]),
        .WVALID_S  (WVALID_S4),
        .WREADY_S  (WREADY_S4),

        // Write Response Channel
        .BID_S     (BID_S4[3:0] ),
        .BRESP_S   (BRESP_S4),
        .BVALID_S  (BVALID_S4),
        .BREADY_S  (BREADY_S4),
        //
        .WTO(WTO_CDC)
    );
    assign awWire_S4_CDC = {AWID_S4,AWADDR_S4,AWLEN_S4,AWSIZE_S4,AWBURST_S4,AWVALID_S4_CDC};
    async_CDC_1  wdt_wrapper_aw(
        .clk(axi_clk),   //WRITE
        .rst(axi_rst),
        .clk2(rom_clk),  //READ
        .rst2(rom_rst),
        .w_data(awWire_S4_CDC),
        .WEB(!AWVALID_S4_CDC),
        .I_am_ready(AWREADY_S4),
        .ready(AWREADY_S4_CDC),
        .valid(AWVALID_S4),
        .DO(awWire_S4_CDC_AXI)
    ); 


    assign wWire_S4_CDC = {WDATA_S4,WSTRB_S4,WLAST_S4,WVALID_S4_CDC};
    async_CDC_1 wdt_wrapper_w(
        .clk(axi_clk),   //WRITE
        .rst(axi_rst),
        .clk2(rom_clk),  //READ
        .rst2(rom_rst),
        .w_data({12'd0,wWire_S4_CDC}),
        .WEB(!WVALID_S4_CDC),
        .I_am_ready(WREADY_S4),
        .ready(WREADY_S4_CDC),
        .valid(WVALID_S4),
        .DO(wWire_S4_CDC_AXI)
    ); 



    assign bWire_S4_CDC = {BID_S4,BRESP_S4,BVALID_S4};
    async_CDC_1 wdt_wrapper_b(
        .clk(rom_clk),   //WRITE
        .rst(rom_rst),
        .clk2(axi_clk),  //READ
        .rst2(axi_rst),
        .w_data({37'd0,bWire_S4_CDC}),
        .WEB(!BVALID_S4),
        .I_am_ready(BREADY_S4_CDC),
        .ready(BREADY_S4),
        .valid(BVALID_S4_CDC),
        .DO(bWire_S4_CDC_AXI)
    ); 

        DRAM_wrapper u_DRAM_wrapper (
        .clk       (dram_clk),
        .rst       (dram_rst),
        // DRAM signals 
        .Q         (DRAM_Q),  
        .VALID     (DRAM_valid),  
        .CSn       (DRAM_CSn),  
        .WEn       (DRAM_WEn),  
        .RASn      (DRAM_RASn),  
        .CASn      (DRAM_CASn),  
        .A         (DRAM_A),  
        .D         (DRAM_D),  
        // Write Address Channel
        .AWID(awWire_S5_CDC_AXI[49:42]),
        .AWADDR(awWire_S5_CDC_AXI[41:10]),
        .AWLEN({awWire_S5_CDC_AXI[9:6]}),
        .AWSIZE(awWire_S5_CDC_AXI[5:3]),
        .AWBURST(awWire_S5_CDC_AXI[2:1]),
        .AWVALID (AWVALID_S5),
        .AWREADY (AWREADY_S5),

        // Write Data Channel
        .WDATA(wWire_S5_CDC_AXI[37:6]),
        .WSTRB(wWire_S5_CDC_AXI[5:2]),
        .WLAST(wWire_S5_CDC_AXI[1]),
        .WVALID  (WVALID_S5),
        .WREADY  (WREADY_S5),

        // Write Response Channel
        .BID     (BID_S5),
        .BRESP   (BRESP_S5),
        .BVALID  (BVALID_S5),
        .BREADY  (BREADY_S5),

        // Read Address Channel
        .ARID(arWire_S5_CDC_AXI[49:42]),
        .ARADDR(arWire_S5_CDC_AXI[41:10]),
        .ARLEN({arWire_S5_CDC_AXI[9:6]}),
        .ARSIZE(arWire_S5_CDC_AXI[5:3]),
        .ARBURST(arWire_S5_CDC_AXI[2:1]),
        .ARVALID (ARVALID_S5),
        .ARREADY (ARREADY_S5),

        // Read Data Channel
        .RID     (RID_S5),
        .RDATA   (RDATA_S5),
        .RRESP   (RRESP_S5),
        .RLAST   (RLAST_S5),
        .RVALID  (RVALID_S5),
        .RREADY  (RREADY_S5)
);

// ================== EPU Wrapper ==================
    // PE sparse-GEMM engine as AXI slave S6. axi_clk domain (S6 has no CDC).
    // axi_rst is active-high at top level -> wrapper takes ARESETn = ~axi_rst.
    EPU_wrapper u_EPU_wrapper (
        .ACLK       (axi_clk),
        .ARESETn    (~axi_rst),
        .AWID_S6    (AWID_S6),
        .AWADDR_S6  (AWADDR_S6),
        .AWLEN_S6   (AWLEN_S6),
        .AWSIZE_S6  (AWSIZE_S6),
        .AWBURST_S6 (AWBURST_S6),
        .AWVALID_S6 (AWVALID_S6),
        .AWREADY_S6 (AWREADY_S6),
        .WDATA_S6   (WDATA_S6),
        .WSTRB_S6   (WSTRB_S6),
        .WLAST_S6   (WLAST_S6),
        .WVALID_S6  (WVALID_S6),
        .WREADY_S6  (WREADY_S6),
        .BID_S6     (BID_S6),
        .BRESP_S6   (BRESP_S6),
        .BVALID_S6  (BVALID_S6),
        .BREADY_S6  (BREADY_S6),
        .ARID_S6    (ARID_S6),
        .ARADDR_S6  (ARADDR_S6),
        .ARLEN_S6   (ARLEN_S6),
        .ARSIZE_S6  (ARSIZE_S6),
        .ARBURST_S6 (ARBURST_S6),
        .ARVALID_S6 (ARVALID_S6),
        .ARREADY_S6 (ARREADY_S6),
        .RID_S6     (RID_S6),
        .RDATA_S6   (RDATA_S6),
        .RRESP_S6   (RRESP_S6),
        .RLAST_S6   (RLAST_S6),
        .RVALID_S6  (RVALID_S6),
        .RREADY_S6  (RREADY_S6)
    );

assign arWire_S5_CDC = {ARID_S5,ARADDR_S5,ARLEN_S5,ARSIZE_S5,ARBURST_S5,ARVALID_S5_CDC};
async_CDC_1  dram_wrapper_ar(
     .clk(axi_clk),   //WRITE
     .rst(axi_rst),
     .clk2(dram_clk),  //READ
     .rst2(dram_rst),
     .w_data(arWire_S5_CDC),
     .WEB(!ARVALID_S5_CDC),
     .I_am_ready(ARREADY_S5),
     .ready(ARREADY_S5_CDC),
     .valid(ARVALID_S5),
     .DO(arWire_S5_CDC_AXI)
); 


assign rWire_S5_CDC = {RID_S5,RDATA_S5,RRESP_S5,RLAST_S5,RVALID_S5};
async_CDC_16  dram_wrapper_r(
     .clk(dram_clk),   //WRITE
     .rst(dram_rst),
     .clk2(axi_clk),  //READ
     .rst2(axi_rst),
     .w_data({6'd0,rWire_S5_CDC}),
     .WEB(!RVALID_S5),
     .I_am_ready(RREADY_S5_CDC),
     .ready(RREADY_S5),
     .valid(RVALID_S5_CDC),
     .DO(rWire_S5_CDC_AXI)
); 


assign awWire_S5_CDC = {AWID_S5,AWADDR_S5,AWLEN_S5,AWSIZE_S5,AWBURST_S5,AWVALID_S5_CDC};
async_CDC_1  dram_wrapper_aw(
     .clk(axi_clk),   //WRITE
     .rst(axi_rst),
     .clk2(dram_clk),  //READ
     .rst2(dram_rst),
     .w_data(awWire_S5_CDC),
     .WEB(!AWVALID_S5_CDC),
     .I_am_ready(AWREADY_S5),
     .ready(AWREADY_S5_CDC),
     .valid(AWVALID_S5),
     .DO(awWire_S5_CDC_AXI)
); 


assign wWire_S5_CDC = {WDATA_S5,WSTRB_S5,WLAST_S5,WVALID_S5_CDC};
async_CDC_1  dram_wrapper_w(
     .clk(axi_clk),   //WRITE
     .rst(axi_rst),
     .clk2(dram_clk),  //READ
     .rst2(dram_rst),
     .w_data({12'd0,wWire_S5_CDC}),
     .WEB(!WVALID_S5_CDC),
     .I_am_ready(WREADY_S5),
     .ready(WREADY_S5_CDC),
     .valid(WVALID_S5),
     .DO(wWire_S5_CDC_AXI)
); 


assign bWire_S5_CDC = {BID_S5,BRESP_S5,BVALID_S5};
async_CDC_1 dram_wrapper_b(
     .clk(dram_clk),   //WRITE
     .rst(dram_rst),
     .clk2(axi_clk),  //READ
     .rst2(axi_rst),
     .w_data({39'd0,bWire_S5_CDC}),
     .WEB(!BVALID_S5),
     .I_am_ready(BREADY_S5_CDC),
     .ready(BREADY_S5),
     .valid(BVALID_S5_CDC),
     .DO(bWire_S5_CDC_AXI)
); 

//-------------------------  Interrupt --------------------------------//
ONE_CDC one_cdc_ext(
  .clk(cpu_clk),  //WRITE
  .rst(cpu_rst),
  .clk2(cpu_clk), //READ
  .rst2(cpu_rst),
  .in(interrupt),
  .out(interrupt_CDC)
  );

endmodule