`include "AXI_define.svh"

module AXI(

	input ACLK,
	input ARESETn,

    //////////MASTER INTERFACE//////////
    //READ ADDRESS 0
    input         [`AXI_ID_BITS-1:0]    ARID_M0,
    input         [`AXI_ADDR_BITS-1:0]  ARADDR_M0,
    input         [3:0]                 ARLEN_M0,
    input         [`AXI_SIZE_BITS-1:0]  ARSIZE_M0,
    input         [1:0]                 ARBURST_M0,
    input                               ARVALID_M0,
    output  logic                       ARREADY_M0,
    
    //READ DATA 0
    output  logic [`AXI_ID_BITS-1:0]    RID_M0,
    output  logic [`AXI_DATA_BITS-1:0]  RDATA_M0,
    output  logic [1:0]                 RRESP_M0,
    output  logic                       RLAST_M0,
    output  logic                       RVALID_M0,
    input                               RREADY_M0,
    
    //READ ADDRESS 1
    input         [`AXI_ID_BITS-1:0]    ARID_M1,
    input         [`AXI_ADDR_BITS-1:0]  ARADDR_M1,
    input         [3:0]                 ARLEN_M1,
    input         [`AXI_SIZE_BITS-1:0]  ARSIZE_M1,
    input         [1:0]                 ARBURST_M1,
    input                               ARVALID_M1,
    output  logic                       ARREADY_M1,
    
    //READ DATA 1
    output  logic [`AXI_ID_BITS-1:0]    RID_M1,
    output  logic [`AXI_DATA_BITS-1:0]  RDATA_M1,
    output  logic [1:0]                 RRESP_M1,
    output  logic                       RLAST_M1,
    output  logic                       RVALID_M1,
    input                               RREADY_M1,

    //WRITE ADDRESS 1
    input         [`AXI_ID_BITS-1:0]    AWID_M1,
    input         [`AXI_ADDR_BITS-1:0]  AWADDR_M1,
    input         [3:0]                 AWLEN_M1,
    input         [`AXI_SIZE_BITS-1:0]  AWSIZE_M1,
    input         [1:0]                 AWBURST_M1,
    input                               AWVALID_M1,
    output  logic                       AWREADY_M1,
    
    //WRITE DATA 1
    input         [`AXI_DATA_BITS-1:0]  WDATA_M1,
    input         [`AXI_STRB_BITS-1:0]  WSTRB_M1,
    input                               WLAST_M1,
    input                               WVALID_M1,
    output  logic                       WREADY_M1,
    
    //WRITE RESPONSE 1
    output  logic [`AXI_ID_BITS-1:0]    BID_M1,
    output  logic [1:0]                 BRESP_M1,
    output  logic                       BVALID_M1,
    input                               BREADY_M1,

    //Read Address 2
    input   logic [`AXI_ID_BITS-1:0]    ARID_M2,
    input   logic [`AXI_ADDR_BITS-1:0]  ARADDR_M2,
    input   logic [3:0]                 ARLEN_M2,
    input   logic [`AXI_SIZE_BITS-1:0]  ARSIZE_M2,
    input   logic [1:0]                 ARBURST_M2,
    input   logic                       ARVALID_M2,
    output  logic                       ARREADY_M2,
    
    //Read Data 2
    output  logic [`AXI_ID_BITS-1:0]    RID_M2,
    output  logic [`AXI_DATA_BITS-1:0]  RDATA_M2,
    output  logic [1:0]                 RRESP_M2,
    output  logic                       RLAST_M2,
    output  logic                       RVALID_M2,
    input   logic                       RREADY_M2,
    
    //Write Address 2
    input   logic [`AXI_ID_BITS-1:0]    AWID_M2,
    input   logic [`AXI_ADDR_BITS-1:0]  AWADDR_M2,
    input   logic [3:0]                 AWLEN_M2,
    input   logic [`AXI_SIZE_BITS-1:0]  AWSIZE_M2,
    input   logic [1:0]                 AWBURST_M2,
    input   logic                       AWVALID_M2,
    output  logic                       AWREADY_M2,
    
    //Write Data 2
    input   logic [`AXI_DATA_BITS-1:0]  WDATA_M2,
    input   logic [`AXI_STRB_BITS-1:0]  WSTRB_M2,
    input   logic                       WLAST_M2,
    input   logic                       WVALID_M2,
    output  logic                       WREADY_M2,
    
    //Write Response 2
    output  logic [`AXI_ID_BITS-1:0]    BID_M2,
    output  logic [1:0]                 BRESP_M2,
    output  logic                       BVALID_M2,
    input   logic                       BREADY_M2,

    //////////SLAVE INTERFACE//////////
    //WRITE ADDRESS 1 (S1 - IM)
    output  logic [`AXI_IDS_BITS-1:0]   AWID_S1,
    output  logic [`AXI_ADDR_BITS-1:0]  AWADDR_S1,
    output  logic [3:0]                 AWLEN_S1,
    output  logic [`AXI_SIZE_BITS-1:0]  AWSIZE_S1,
    output  logic [1:0]                 AWBURST_S1,
    output  logic                       AWVALID_S1,
    input                               AWREADY_S1,
    
    //WRITE DATA 1 (S1 - IM)
    output  logic [`AXI_DATA_BITS-1:0]  WDATA_S1,
    output  logic [`AXI_STRB_BITS-1:0]  WSTRB_S1,
    output  logic                       WLAST_S1,
    output  logic                       WVALID_S1,
    input                               WREADY_S1,
    
    //WRITE RESPONSE 1 (S1 - IM)
    input         [`AXI_IDS_BITS-1:0]   BID_S1,
    input         [1:0]                 BRESP_S1,
    input                               BVALID_S1,
    output  logic                       BREADY_S1,
    
    //WRITE ADDRESS 2 (S2 - DM)
    output  logic [`AXI_IDS_BITS-1:0]   AWID_S2,
    output  logic [31:0]                AWADDR_S2,
    output  logic [3:0]                 AWLEN_S2,
    output  logic [`AXI_SIZE_BITS-1:0]  AWSIZE_S2,
    output  logic [1:0]                 AWBURST_S2,
    output  logic                       AWVALID_S2,
    input                               AWREADY_S2,
    
    //WRITE DATA 2 (S2 - DM)
    output  logic [`AXI_DATA_BITS-1:0]  WDATA_S2,
    output  logic [`AXI_STRB_BITS-1:0]  WSTRB_S2,
    output  logic                       WLAST_S2,
    output  logic                       WVALID_S2,
    input                               WREADY_S2,
    
    //WRITE RESPONSE 2 (S2 - DM)
    input         [`AXI_IDS_BITS-1:0]   BID_S2,
    input         [1:0]                 BRESP_S2,
    input                               BVALID_S2,
    output  logic                       BREADY_S2,

    //WRITE ADDRESS 3 (S3 - DMA)
    output  logic [`AXI_IDS_BITS-1:0]   AWID_S3,
    output  logic [`AXI_ADDR_BITS-1:0]  AWADDR_S3,
    output  logic [3:0]                 AWLEN_S3,
    output  logic [`AXI_SIZE_BITS-1:0]  AWSIZE_S3,
    output  logic [1:0]                 AWBURST_S3,
    output  logic                       AWVALID_S3,
    input                               AWREADY_S3,

    //WRITE DATA 3 (S3 - DMA)
    output  logic [`AXI_DATA_BITS-1:0]  WDATA_S3,
    output  logic [`AXI_STRB_BITS-1:0]  WSTRB_S3,
    output  logic                       WLAST_S3,
    output  logic                       WVALID_S3,
    input                               WREADY_S3,

    //WRITE RESPONSE 3 (S3 - DMA)
    input         [`AXI_IDS_BITS-1:0]   BID_S3,
    input         [1:0]                 BRESP_S3,
    input                               BVALID_S3,
    output  logic                       BREADY_S3,

    //WRITE ADDRESS 4 (S4 - WDT)
    output  logic [`AXI_IDS_BITS-1:0]   AWID_S4,
    output  logic [`AXI_ADDR_BITS-1:0]  AWADDR_S4,
    output  logic [3:0]                 AWLEN_S4,
    output  logic [`AXI_SIZE_BITS-1:0]  AWSIZE_S4,
    output  logic [1:0]                 AWBURST_S4,
    output  logic                       AWVALID_S4,
    input                               AWREADY_S4,
    //WRITE DATA 4 (S4 - WDT)
    output  logic [`AXI_DATA_BITS-1:0]  WDATA_S4,
    output  logic [`AXI_STRB_BITS-1:0]  WSTRB_S4,
    output  logic                       WLAST_S4,
    output  logic                       WVALID_S4,
    input                               WREADY_S4,
    //WRITE RESPONSE 4 (S4 - WDT)
    input         [`AXI_IDS_BITS-1:0]   BID_S4,
    input         [1:0]                 BRESP_S4,
    input                               BVALID_S4,
    output  logic                       BREADY_S4,
    
    //WRITE ADDRESS 5 (S5 - DRAM)
    output  logic [`AXI_IDS_BITS-1:0]   AWID_S5,
    output  logic [`AXI_ADDR_BITS-1:0]  AWADDR_S5,
    output  logic [3:0]                 AWLEN_S5,
    output  logic [`AXI_SIZE_BITS-1:0]  AWSIZE_S5,
    output  logic [1:0]                 AWBURST_S5,
    output  logic                       AWVALID_S5,
    input                               AWREADY_S5,
    
    //WRITE DATA 5 (S5 - DRAM)
    output  logic [`AXI_DATA_BITS-1:0]  WDATA_S5,
    output  logic [`AXI_STRB_BITS-1:0]  WSTRB_S5,
    output  logic                       WLAST_S5,
    output  logic                       WVALID_S5,
    input                               WREADY_S5,
    
    //WRITE RESPONSE 5 (S5 - DRAM)
    input         [`AXI_IDS_BITS-1:0]   BID_S5,
    input         [1:0]                 BRESP_S5,
    input                               BVALID_S5,
    output  logic                       BREADY_S5,

    //WRITE ADDRESS 6 (S6 - EPU)
    output  logic [`AXI_IDS_BITS-1:0]   AWID_S6,
    output  logic [`AXI_ADDR_BITS-1:0]  AWADDR_S6,
    output  logic [3:0]                 AWLEN_S6,
    output  logic [`AXI_SIZE_BITS-1:0]  AWSIZE_S6,
    output  logic [1:0]                 AWBURST_S6,
    output  logic                       AWVALID_S6,
    input                               AWREADY_S6,
    
    //WRITE DATA 6 (S6 - EPU)
    output  logic [`AXI_DATA_BITS-1:0]  WDATA_S6,
    output  logic [`AXI_STRB_BITS-1:0]  WSTRB_S6,
    output  logic                       WLAST_S6,
    output  logic                       WVALID_S6,
    input                               WREADY_S6,
    
    //WRITE RESPONSE 6 (S6 - EPU)
    input         [`AXI_IDS_BITS-1:0]   BID_S6,
    input         [1:0]                 BRESP_S6,
    input                               BVALID_S6,
    output  logic                       BREADY_S6,

    //READ ADDRESS 0 (S0 - ROM)
    output  logic [`AXI_IDS_BITS-1:0]   ARID_S0,
    output  logic [`AXI_ADDR_BITS-1:0]  ARADDR_S0,
    output  logic [3:0]                 ARLEN_S0,
    output  logic [`AXI_SIZE_BITS-1:0]  ARSIZE_S0,
    output  logic [1:0]                 ARBURST_S0,
    output  logic                       ARVALID_S0,
    input                               ARREADY_S0,

    //READ DATA 0 (S0 - ROM)
    input         [`AXI_IDS_BITS-1:0]   RID_S0,
    input         [`AXI_DATA_BITS-1:0]  RDATA_S0,
    input         [1:0]                 RRESP_S0,
    input                               RLAST_S0,
    input                               RVALID_S0,
    output  logic                       RREADY_S0,

    //READ ADDRESS 1 (S1 - IM)
    output  logic [`AXI_IDS_BITS-1:0]   ARID_S1,
    output  logic [`AXI_ADDR_BITS-1:0]  ARADDR_S1,
    output  logic [3:0]                 ARLEN_S1,
    output  logic [`AXI_SIZE_BITS-1:0]  ARSIZE_S1,
    output  logic [1:0]                 ARBURST_S1,
    output  logic                       ARVALID_S1,
    input                               ARREADY_S1,
    
    //READ DATA 1 (S1 - IM)
    input         [`AXI_IDS_BITS-1:0]   RID_S1,
    input         [`AXI_DATA_BITS-1:0]  RDATA_S1,
    input         [1:0]                 RRESP_S1,
    input                               RLAST_S1,
    input                               RVALID_S1,
    output  logic                       RREADY_S1,
    
    //READ ADDRESS 2 (S2 - DM)
    output  logic [`AXI_IDS_BITS-1:0]   ARID_S2,
    output  logic [`AXI_ADDR_BITS-1:0]  ARADDR_S2,
    output  logic [3:0]                 ARLEN_S2,
    output  logic [`AXI_SIZE_BITS-1:0]  ARSIZE_S2,
    output  logic [1:0]                 ARBURST_S2,
    output  logic                       ARVALID_S2,
    input                               ARREADY_S2,
    
    //READ DATA 2 (S2 - DM)
    input         [`AXI_IDS_BITS-1:0]   RID_S2,
    input         [`AXI_DATA_BITS-1:0]  RDATA_S2,
    input         [1:0]                 RRESP_S2,
    input                               RLAST_S2,
    input                               RVALID_S2,
    output  logic                       RREADY_S2,

    //READ ADDRESS 5 (S5 - DRAM)
    output  logic [`AXI_IDS_BITS-1:0]   ARID_S5,
    output  logic [`AXI_ADDR_BITS-1:0]  ARADDR_S5,
    output  logic [3:0]                 ARLEN_S5,
    output  logic [`AXI_SIZE_BITS-1:0]  ARSIZE_S5,
    output  logic [1:0]                 ARBURST_S5,
    output  logic                       ARVALID_S5,
    input                               ARREADY_S5,
    
    //READ DATA 5 (S5 - DRAM)
    input         [`AXI_IDS_BITS-1:0]   RID_S5,
    input         [`AXI_DATA_BITS-1:0]  RDATA_S5,
    input         [1:0]                 RRESP_S5,
    input                               RLAST_S5,
    input                               RVALID_S5,
    output  logic                       RREADY_S5,
	
    //READ ADDRESS 6 (S6 - EPU)
    output  logic [`AXI_IDS_BITS-1:0]   ARID_S6,
    output  logic [`AXI_ADDR_BITS-1:0]  ARADDR_S6,
    output  logic [3:0]                 ARLEN_S6,
    output  logic [`AXI_SIZE_BITS-1:0]  ARSIZE_S6,
    output  logic [1:0]                 ARBURST_S6,
    output  logic                       ARVALID_S6,
    input                               ARREADY_S6,
    
    //READ DATA 6 (S6 - EPU)
    input         [`AXI_IDS_BITS-1:0]   RID_S6,
    input         [`AXI_DATA_BITS-1:0]  RDATA_S6,
    input         [1:0]                 RRESP_S6,
    input                               RLAST_S6,
    input                               RVALID_S6,
    output  logic                       RREADY_S6
);

logic [3:0] arid_m0_reg,arid_m1_reg,awid_m1_reg;


//Read FSM
enum logic [3:0] { 
        IDLE_r,
        M0_S0_r,
        M0_S1_r,
        M0_S2_r,
        M0_S5_r,
        M0_S6_r,
        M1_S0_r,
        M1_S1_r,
        M1_S2_r,
        M1_S5_r,
        M1_S6_r,
        M2_S2_r,
        M2_S5_r,
        M2_S6_r,
        M0_default,
        M1_default
 } state_r,next_state_r;

enum logic [3:0] {
				slave0_r,
				slave1_r,
        slave2_r,
        slave5_r,
        slave6_r,
				default_slave_r,
        none_slave_r
} slave_m0_r,slave_m1_r;

always_comb begin
    if (ARVALID_M0) begin
        slave_m0_r = (ARADDR_M0[31:16] == 16'h0000)?slave0_r:
                     (ARADDR_M0[31:16] == 16'h0001)?slave1_r:
                     (ARADDR_M0[31:16] == 16'h0002)?slave2_r:
                     (ARADDR_M0[31:16] >= 16'h2000 && ARADDR_M0[31:16] <= 16'h201F)?slave5_r:
                     (ARADDR_M0[31:16] == 16'h0005) ? slave6_r :
                     none_slave_r;
    end else begin
        slave_m0_r = none_slave_r;
    end
end

always_comb begin
    if ((state_r == IDLE_r) || ARVALID_M1) begin
        slave_m1_r = (ARADDR_M1[31:16] == 16'h0000)?slave0_r:
                     (ARADDR_M1[31:16] == 16'h0001)?slave1_r:
                     (ARADDR_M1[31:16] == 16'h0002)?slave2_r:
                     (ARADDR_M1[31:16] >= 16'h2000 && ARADDR_M1[31:16] <= 16'h201F)?slave5_r:
                     (ARADDR_M1[31:16] == 16'h0005) ? slave6_r :
                     none_slave_r;
    end else begin
        slave_m1_r = none_slave_r;
    end
end

//Write FSM
enum logic [3:0] { 
        IDLE_w,
        M1_S1_w,
        M1_S2_w,
        M1_S3_w,
        M1_S4_w,
        M1_S5_w,
        M1_S6_w,
        M2_S1_w,
        M2_S2_w,
        M2_S6_w,
        M1_default_w
 } state_w,next_state_w;

 enum logic [3:0] {
				slave1_w,
				slave2_w,
				slave3_w,
				slave4_w,
        slave5_w,
        slave6_w,
				default_slave_w,
        none_slave_w
 } slave_m1_w,slave_m2_w;

always_comb begin
    if ((state_w == IDLE_w) || AWVALID_M1) begin
        slave_m1_w = (AWADDR_M1[31:16] == 16'h0001)?slave1_w:
                     (AWADDR_M1[31:16] == 16'h0002)?slave2_w:
                     (AWADDR_M1 >= 32'h1002_0000 && AWADDR_M1 <= 32'h1002_0400)?slave3_w:
                     (AWADDR_M1 >= 32'h1001_0000 && AWADDR_M1 <= 32'h1001_03FF)?slave4_w:
                     (AWADDR_M1[31:16] >= 16'h2000 && AWADDR_M1[31:16] <= 16'h201F)?slave5_w:
                     (AWADDR_M1[31:16] == 16'h0005)?slave6_w:
                     none_slave_w;   
    end else begin
        slave_m1_w = none_slave_w;
    end
end

always_comb begin
    if((state_w == IDLE_w) || AWVALID_M2) begin
       slave_m2_w = (AWADDR_M2[31:16] == 16'h0001)?slave1_w:
                    (AWADDR_M2[31:16] == 16'h0002)?slave2_w:
                    (AWADDR_M2[31:16] == 16'h0005)?slave6_w:
                    none_slave_w;
    end else begin
        slave_m2_w = none_slave_w;
    end
end
logic slave2_m2_r, slave5_m2_r, slave6_m2_r;

assign slave2_m2_r = (ARADDR_M2[31:16] == 16'h0002);
assign slave5_m2_r = (ARADDR_M2[31:16] >= 16'h2000 && ARADDR_M2[31:16] <= 16'h201F);
assign slave6_m2_r = (ARADDR_M2[31:16] == 16'h0005);

always @(posedge ACLK or negedge ARESETn) begin
    if (~ARESETn) begin
        state_r <= IDLE_r;
        state_w <= IDLE_w; 
    end else begin
        state_r <= next_state_r;
        state_w <= next_state_w;
    end
end
//遇到default_slave要回傳一樣的ARID，先暫存器所住
always @(posedge ACLK or negedge ARESETn) begin
  if (~ARESETn) begin
    arid_m1_reg <= 4'd0;
    arid_m0_reg <= 4'd0;
  end else if (state_r == IDLE_r) begin
    arid_m1_reg <= 4'd0;
    arid_m0_reg <= 4'd0;
  end else if (state_r == M0_default) begin
    arid_m0_reg <= ARID_M0;
    arid_m1_reg <= arid_m1_reg;
  end else if (state_r == M1_default) begin
    arid_m0_reg <= arid_m0_reg;
    arid_m1_reg <= ARID_M1;
  end else begin
    arid_m0_reg <= arid_m0_reg;
    arid_m1_reg <= arid_m1_reg;
  end
end
//遇到default_slave要回傳一樣的AWID，先暫存器所住
always @(posedge ACLK or negedge ARESETn) begin
  if (~ARESETn) begin
    awid_m1_reg <= 4'd0;
  end else if (state_w == IDLE_w) begin
    awid_m1_reg <= 4'd0;
  end else if (state_w == M1_default_w) begin
    awid_m1_reg <= AWID_M1;
  end else begin
    awid_m1_reg <= awid_m1_reg;
  end
end

always_comb begin
  case(state_r)
    IDLE_r:begin
      next_state_r = (ARVALID_M2 &&  slave5_m2_r)?M2_S5_r:
                     (ARVALID_M2 &&  slave2_m2_r)?M2_S2_r:
                     (ARVALID_M2 &&  slave6_m2_r)?M2_S6_r:            
                     (ARVALID_M0 && (slave_m0_r == slave0_r))?M0_S0_r: 
                     (ARVALID_M0 && (slave_m0_r == slave1_r))?M0_S1_r:
                     (ARVALID_M0 && (slave_m0_r == slave2_r))?M0_S2_r:
                     (ARVALID_M0 && (slave_m0_r == slave5_r))?M0_S5_r:
                     (ARVALID_M0 && (slave_m0_r == slave6_r))?M0_S6_r:
                     (ARVALID_M1 && (slave_m1_r == slave0_r))?M1_S0_r:
                     (ARVALID_M1 && (slave_m1_r == slave1_r))?M1_S1_r:
                     (ARVALID_M1 && (slave_m1_r == slave2_r))?M1_S2_r:
                     (ARVALID_M1 && (slave_m1_r == slave5_r))?M1_S5_r:
                     (ARVALID_M1 && (slave_m1_r == slave6_r))?M1_S6_r:
                                                              IDLE_r;    
		end
		M0_S0_r:begin
			next_state_r = (RLAST_M0 && RREADY_M0 && RVALID_M0 && ~ARVALID_M0)				?IDLE_r:M0_S0_r;
		end	
		M0_S1_r:begin
			next_state_r = (RLAST_M0 && RREADY_M0 && RVALID_M0 && ~ARVALID_M0)				?IDLE_r:M0_S1_r;
		end	
		M0_S2_r:begin
			next_state_r = (RLAST_M0 && RREADY_M0 && RVALID_M0 && ~ARVALID_M0)				?IDLE_r:M0_S2_r;
		end
		M0_S5_r:begin
			next_state_r = (RLAST_M0 && RREADY_M0 && RVALID_M0 && ~ARVALID_M0)				?IDLE_r:M0_S5_r;
		end	 
    M0_S6_r:begin
      next_state_r = (RLAST_S6 && RREADY_M0 && RVALID_S6 && ~ARVALID_M0)        ?IDLE_r:M0_S6_r;   	    
    end
    M1_S0_r:begin
			next_state_r = (RLAST_M1 && RREADY_M1 && RVALID_M1 && ~ARVALID_M1)				?IDLE_r:M1_S0_r;
		end	
		M1_S1_r:begin
			next_state_r = (RLAST_M1 && RREADY_M1 && RVALID_M1 && ~ARVALID_M1)				?IDLE_r:M1_S1_r;
		end
		M1_S2_r:begin
			next_state_r = (RLAST_M1 && RREADY_M1 && RVALID_M1 && ~ARVALID_M1)				?IDLE_r:M1_S2_r;
		end  
    M1_S5_r:begin
			next_state_r = (RLAST_M1 && RREADY_M1 && RVALID_M1 && ~ARVALID_M1)				?IDLE_r:M1_S5_r;
		end
    M1_S6_r:begin
      next_state_r = (RLAST_S6 && RREADY_M1 && RVALID_S6 && ~ARVALID_M1)        ?IDLE_r:M1_S6_r;   	    
    end
    M2_S2_r:begin
      next_state_r = (RLAST_M2 && RREADY_M2 && RVALID_M2 && ~ARVALID_M2)				?IDLE_r:M2_S2_r;
    end
    M2_S5_r:begin
      next_state_r = (RLAST_M2 && RREADY_M2 && RVALID_M2 && ~ARVALID_M2)				?IDLE_r:M2_S5_r;
    end 
    M2_S6_r:begin
      next_state_r = (RLAST_S6 && RREADY_M2 && RVALID_S6 && ~ARVALID_M2)        ?IDLE_r:M2_S6_r;   	    
    end
    // M0_default:begin
    //   next_state_r = (RLAST_M0 && RREADY_M0 && RVALID_M0 && ~ARVALID_M0)        ?IDLE_r:M0_default;
    // end	
    // M1_default:begin
    //   next_state_r = (RLAST_M1 && RREADY_M1 && RVALID_M1 && ~ARVALID_M1)        ?IDLE_r:M1_default;
    // end	
    default:begin
      next_state_r =IDLE_r;
    end			
  endcase
end


always_comb begin
	case (state_w)
		IDLE_w:begin
			next_state_w = (AWVALID_M2 && (slave_m2_w == slave1_w))			    ?M2_S1_w:
										 (AWVALID_M2 && (slave_m2_w == slave2_w))			    ?M2_S2_w:
                     (AWVALID_M2 && (slave_m2_w == slave6_w))         ?M2_S6_w:
                     (AWVALID_M1 && (slave_m1_w == slave1_w))         ?M1_S1_w:
                     (AWVALID_M1 && (slave_m1_w == slave2_w))         ?M1_S2_w:
                     (AWVALID_M1 && (slave_m1_w == slave3_w))         ?M1_S3_w:
                     (AWVALID_M1 && (slave_m1_w == slave4_w))         ?M1_S4_w:
                     (AWVALID_M1 && (slave_m1_w == slave5_w))         ?M1_S5_w:
                     (AWVALID_M1 && (slave_m1_w == slave6_w))         ?M1_S6_w:
										 													                         IDLE_w;																												
		end 
		M2_S1_w:begin
			next_state_w = (BVALID_M2 && BREADY_M2)										    ?IDLE_w:M2_S1_w;
		end	
		M2_S2_w:begin
			next_state_w = (BVALID_M2 && BREADY_M2)										    ?IDLE_w:M2_S2_w;
		end
    M2_S6_w:begin
      next_state_w = (BVALID_S6 && BREADY_M2)                       ? IDLE_w : M2_S6_w;
    end
    M1_S1_w:begin
      next_state_w = (BVALID_M1 && BREADY_M1)                       ?IDLE_w:M1_S1_w;
    end
    M1_S2_w:begin
      next_state_w = (BVALID_M1 && BREADY_M1)                       ?IDLE_w:M1_S2_w;
    end
    M1_S3_w:begin
      next_state_w = (BVALID_M1 && BREADY_M1)                       ?IDLE_w:M1_S3_w;
    end
    M1_S4_w:begin
      next_state_w = (BVALID_M1 && BREADY_M1)                       ?IDLE_w:M1_S4_w;
    end
    M1_S5_w:begin
      next_state_w = (BVALID_M1 && BREADY_M1)                       ?IDLE_w:M1_S5_w;
    end
    M1_S6_w:begin
      next_state_w = (BVALID_S6 && BREADY_M1)                       ? IDLE_w : M1_S6_w;
    end
    default:begin
      next_state_w = IDLE_w;
    end	
	endcase
end

//M0 READ
	assign ARREADY_M0 = (state_r == M0_S0_r)? ARREADY_S0 : 
                      (state_r == M0_S1_r)? ARREADY_S1 : 
                      (state_r == M0_S2_r)? ARREADY_S2 : 
                      (state_r == M0_S5_r)? ARREADY_S5 :
                      (state_r == M0_S6_r)? ARREADY_S6 : 1'd0;

	assign RID_M0    =  (state_r == M0_S0_r)? RID_S0[3:0] : 
                      (state_r == M0_S1_r)? RID_S1[3:0] :
                      (state_r == M0_S2_r)? RID_S2[3:0] :
                      (state_r == M0_S5_r)? RID_S5[3:0] : 
                      (state_r == M0_S6_r)? RID_S6[3:0] : 4'd0;

  assign RDATA_M0  =  (state_r == M0_S0_r)? RDATA_S0    : 
                      (state_r == M0_S1_r)? RDATA_S1    : 
                      (state_r == M0_S2_r)? RDATA_S2    : 
                      (state_r == M0_S5_r)? RDATA_S5    :
                      (state_r == M0_S6_r)? RDATA_S6    : 32'd0;

  assign RRESP_M0  =  (state_r == M0_S0_r)? RRESP_S0    : 
                      (state_r == M0_S1_r)? RRESP_S1    :
                      (state_r == M0_S2_r)? RRESP_S2    : 
                      (state_r == M0_S5_r)? RRESP_S5    :
                      (state_r == M0_S6_r)? RRESP_S6    : 2'd0;

  assign RLAST_M0  =  (state_r == M0_S0_r)? RLAST_S0    :
                      (state_r == M0_S1_r)? RLAST_S1    : 
                      (state_r == M0_S2_r)? RLAST_S2    :
                      (state_r == M0_S5_r)? RLAST_S5    :
                      (state_r == M0_S6_r)? RLAST_S6    : 1'd0;

  assign RVALID_M0 =  (state_r == M0_S0_r)? RVALID_S0   : 
                      (state_r == M0_S1_r)? RVALID_S1   : 
                      (state_r == M0_S2_r)? RVALID_S2   : 
                      (state_r == M0_S5_r)? RVALID_S5   :
                      (state_r == M0_S6_r)? RVALID_S6   : 1'd0;

//M1 READ
  assign ARREADY_M1 = (state_r == M1_S0_r)? ARREADY_S0  :
                      (state_r == M1_S1_r)? ARREADY_S1  :
                      (state_r == M1_S2_r)? ARREADY_S2  :
                      (state_r == M1_S5_r)? ARREADY_S5  :
                      (state_r == M1_S6_r)? ARREADY_S6  : 1'd0;

  assign RID_M1    =  (state_r == M1_S0_r)? RID_S0[3:0] :
                      (state_r == M1_S1_r)? RID_S1[3:0] :
                      (state_r == M1_S2_r)? RID_S2[3:0] :
                      (state_r == M1_S5_r)? RID_S5[3:0] :
                      (state_r == M1_S6_r)? RID_S6[3:0] : 4'd0;

  assign RDATA_M1  =  (state_r == M1_S0_r)? RDATA_S0    :
                      (state_r == M1_S1_r)? RDATA_S1    :
                      (state_r == M1_S2_r)? RDATA_S2    :
                      (state_r == M1_S5_r)? RDATA_S5    :
                      (state_r == M1_S6_r)? RDATA_S6    : 32'd0;

  assign RRESP_M1  =  (state_r == M1_S0_r)? RRESP_S0    :
                      (state_r == M1_S1_r)? RRESP_S1    :
                      (state_r == M1_S2_r)? RRESP_S2    :
                      (state_r == M1_S5_r)? RRESP_S5    :
                      (state_r == M1_S6_r)? RRESP_S6    : 2'd0;

  assign RLAST_M1  =  (state_r == M1_S0_r)? RLAST_S0    :
                      (state_r == M1_S1_r)? RLAST_S1    :
                      (state_r == M1_S2_r)? RLAST_S2    :
                      (state_r == M1_S5_r)? RLAST_S5    :
                      (state_r == M1_S6_r)? RLAST_S6    : 1'd0;

  assign RVALID_M1 =  (state_r == M1_S0_r)? RVALID_S0   :
                      (state_r == M1_S1_r)? RVALID_S1   :
                      (state_r == M1_S2_r)? RVALID_S2   :
                      (state_r == M1_S5_r)? RVALID_S5   :
                      (state_r == M1_S6_r)? RVALID_S6   : 1'd0;

//M2 READ
  assign  ARREADY_M2  = (state_r == M2_S5_r) ? ARREADY_S5    : (state_r == M2_S2_r) ? ARREADY_S2  : 1'b0;
  assign  RID_M2      = (state_r == M2_S5_r) ? RID_S5[3:0]   : (state_r == M2_S2_r) ? RID_S2[3:0] :`AXI_ID_BITS'd0;
  assign  RDATA_M2    = (state_r == M2_S5_r) ? RDATA_S5      : (state_r == M2_S2_r) ? RDATA_S2    :`AXI_DATA_BITS'd0;
  assign  RRESP_M2    = (state_r == M2_S5_r) ? RRESP_S5      : (state_r == M2_S2_r) ? RRESP_S2    :2'd0;
  assign  RLAST_M2    = (state_r == M2_S5_r) ? RLAST_S5      : (state_r == M2_S2_r) ? RLAST_S2    :1'b0;
  assign  RVALID_M2   = (state_r == M2_S5_r) ? RVALID_S5     : (state_r == M2_S2_r) ? RVALID_S2   :1'b0;                                         
//----------------------------------------------------------------------------------//
// --- READ S0 ---


	assign ARID_S0    = (state_r == M0_S0_r)? {4'd0,ARID_M0} : (state_r == M1_S0_r) ? {4'd0,ARID_M1} : 8'd0;
	assign ARADDR_S0  = (state_r == M0_S0_r)? ARADDR_M0      : (state_r == M1_S0_r) ? ARADDR_M1      : 32'd0;
	assign ARLEN_S0   = (state_r == M0_S0_r)? ARLEN_M0       : (state_r == M1_S0_r) ? ARLEN_M1       : 4'd0;
	assign ARSIZE_S0  = (state_r == M0_S0_r)? ARSIZE_M0      : (state_r == M1_S0_r) ? ARSIZE_M1      : 3'd0;
	assign ARBURST_S0 = (state_r == M0_S0_r)? ARBURST_M0     : (state_r == M1_S0_r) ? ARBURST_M1     : 2'd0;
	assign ARVALID_S0 = (state_r == M0_S0_r)? ARVALID_M0     : (state_r == M1_S0_r) ? ARVALID_M1     : 1'd0;
	assign RREADY_S0 =  (state_r == M0_S0_r)? RREADY_M0      : (state_r == M1_S0_r) ? RREADY_M1      : 1'd0;
// --- READ S1 ---

	assign ARID_S1    = (state_r == M0_S1_r)? {4'd0,ARID_M0} : (state_r == M1_S1_r) ? {4'd0,ARID_M1} : 8'd0;
	assign ARADDR_S1  = (state_r == M0_S1_r)? ARADDR_M0      : (state_r == M1_S1_r) ? ARADDR_M1      : 32'd0;
	assign ARLEN_S1   = (state_r == M0_S1_r)? ARLEN_M0       : (state_r == M1_S1_r) ? ARLEN_M1       : 4'd0;
	assign ARSIZE_S1  = (state_r == M0_S1_r)? ARSIZE_M0      : (state_r == M1_S1_r) ? ARSIZE_M1      : 3'd0;
	assign ARBURST_S1 = (state_r == M0_S1_r)? ARBURST_M0     : (state_r == M1_S1_r) ? ARBURST_M1     : 2'd0;
	assign ARVALID_S1 = (state_r == M0_S1_r)? ARVALID_M0     : (state_r == M1_S1_r) ? ARVALID_M1     : 1'd0;
	assign RREADY_S1  = (state_r == M0_S1_r)? RREADY_M0      : (state_r == M1_S1_r) ? RREADY_M1 : 1'd0;
// --- READ S2 ---
  assign ARID_S2    = (state_r == M0_S2_r)? {4'd0,ARID_M0} : (state_r == M1_S2_r) ? {4'd0,ARID_M1} : (state_r == M2_S2_r) ? {4'd0,ARID_M2} : 8'd0;
  assign ARADDR_S2  = (state_r == M0_S2_r)? ARADDR_M0      : (state_r == M1_S2_r) ? ARADDR_M1      : (state_r == M2_S2_r) ? ARADDR_M2      : 32'd0;
	assign ARLEN_S2   = (state_r == M0_S2_r)? ARLEN_M0       : (state_r == M1_S2_r) ? ARLEN_M1       : (state_r == M2_S2_r) ? ARLEN_M2       : 4'd0;
	assign ARSIZE_S2  = (state_r == M0_S2_r)? ARSIZE_M0      : (state_r == M1_S2_r) ? ARSIZE_M1      : (state_r == M2_S2_r) ? ARSIZE_M2      : 3'd0;
	assign ARBURST_S2 = (state_r == M0_S2_r)? ARBURST_M0     : (state_r == M1_S2_r) ? ARBURST_M1     : (state_r == M2_S2_r) ? ARBURST_M2     : 2'd0;
	assign ARVALID_S2 = (state_r == M0_S2_r)? ARVALID_M0     : (state_r == M1_S2_r) ? ARVALID_M1     : (state_r == M2_S2_r) ? ARVALID_M2     : 1'd0;
	assign RREADY_S2  = (state_r == M0_S2_r)? RREADY_M0      : (state_r == M1_S2_r) ? RREADY_M1      : (state_r == M2_S2_r) ? RREADY_M2      : 1'd0;
// --- READ S5 ---
  assign ARID_S5    = (state_r == M0_S5_r)? {4'd0,ARID_M0} : (state_r == M1_S5_r) ? {4'd0,ARID_M1} : (state_r == M2_S5_r) ? {4'd0,ARID_M2}  : 8'd0;
  assign ARADDR_S5  = (state_r == M0_S5_r)? ARADDR_M0      : (state_r == M1_S5_r) ? ARADDR_M1      : (state_r == M2_S5_r) ?  ARADDR_M2      : 32'd0;
	assign ARLEN_S5   = (state_r == M0_S5_r)? ARLEN_M0       : (state_r == M1_S5_r) ? ARLEN_M1       : (state_r == M2_S5_r) ? ARLEN_M2        : 4'd0;
	assign ARSIZE_S5  = (state_r == M0_S5_r)? ARSIZE_M0      : (state_r == M1_S5_r) ? ARSIZE_M1      : (state_r == M2_S5_r) ? ARSIZE_M2       : 3'd0; 
	assign ARBURST_S5 = (state_r == M0_S5_r)? ARBURST_M0     : (state_r == M1_S5_r) ? ARBURST_M1     : (state_r == M2_S5_r) ? ARBURST_M2      : 2'd0;
	assign ARVALID_S5 = (state_r == M0_S5_r)? ARVALID_M0     : (state_r == M1_S5_r) ? ARVALID_M1     : (state_r == M2_S5_r) ? ARVALID_M2      : 1'd0;
	assign RREADY_S5  = (state_r == M0_S5_r)? RREADY_M0      : (state_r == M1_S5_r) ? RREADY_M1      : (state_r == M2_S5_r) ? RREADY_M2       : 1'd0;
// --- READ S6 (EPU) ---
  assign ARID_S6    = (state_r == M0_S6_r)? {4'd0,ARID_M0} : (state_r == M1_S6_r) ? {4'd0,ARID_M1} : (state_r == M2_S6_r) ? {4'd0,ARID_M2}  : 8'd0;
  assign ARADDR_S6  = (state_r == M0_S6_r)? ARADDR_M0      : (state_r == M1_S6_r) ? ARADDR_M1      : (state_r == M2_S6_r) ?  ARADDR_M2      : 32'd0;
  assign ARLEN_S6   = (state_r == M0_S6_r)? ARLEN_M0       : (state_r == M1_S6_r) ? ARLEN_M1       : (state_r == M2_S6_r) ? ARLEN_M2        : 4'd0;
  assign ARSIZE_S6  = (state_r == M0_S6_r)? ARSIZE_M0      : (state_r == M1_S6_r) ? ARSIZE_M1      : (state_r == M2_S6_r) ? ARSIZE_M2       : 3'd0; 
  assign ARBURST_S6 = (state_r == M0_S6_r)? ARBURST_M0     : (state_r == M1_S6_r) ? ARBURST_M1     : (state_r == M2_S6_r) ? ARBURST_M2      : 2'd0;
  assign ARVALID_S6 = (state_r == M0_S6_r)? ARVALID_M0     : (state_r == M1_S6_r) ? ARVALID_M1     : (state_r == M2_S6_r) ? ARVALID_M2      : 1'd0;
  assign RREADY_S6  = (state_r == M0_S6_r)? RREADY_M0      : (state_r == M1_S6_r) ? RREADY_M1      : (state_r == M2_S6_r) ? RREADY_M2       : 1'd0;

// --- WRITE M1 ---
	assign AWREADY_M1 = (state_w == M1_S1_w)? AWREADY_S1     : 
                      (state_w == M1_S2_w)? AWREADY_S2     :
                      (state_w == M1_S3_w)? AWREADY_S3     : 
                      (state_w == M1_S4_w)? AWREADY_S4     : 
                      (state_w == M1_S5_w)? AWREADY_S5     :
                      (state_w == M1_S6_w)? AWREADY_S6     : 1'd0;

  assign WREADY_M1  = (state_w == M1_S1_w)? WREADY_S1      :
                      (state_w == M1_S2_w)? WREADY_S2      : 
                      (state_w == M1_S3_w)? WREADY_S3      :
                      (state_w == M1_S4_w)? WREADY_S4      : 
                      (state_w == M1_S5_w)? WREADY_S5      :
                      (state_w == M1_S6_w)? WREADY_S6      : 1'd0;

  assign BID_M1     = (state_w == M1_S1_w)? BID_S1[3:0]    :
                      (state_w == M1_S2_w)? BID_S2[3:0]    :
                      (state_w == M1_S3_w)? BID_S3[3:0]    :
                      (state_w == M1_S4_w)? BID_S4[3:0]    : 
                      (state_w == M1_S5_w)? BID_S5[3:0]    :
                      (state_w == M1_S6_w)? BID_S6[3:0]    : 4'd0;

  assign BRESP_M1   = (state_w == M1_S1_w)? BRESP_S1       : 
                      (state_w == M1_S2_w)? BRESP_S2       : 
                      (state_w == M1_S3_w)? BRESP_S3       : 
                      (state_w == M1_S4_w)? BRESP_S4       : 
                      (state_w == M1_S5_w)? BRESP_S5       :
                      (state_w == M1_S6_w)? BRESP_S6       : 2'd0;

  assign BVALID_M1  = (state_w == M1_S1_w)? BVALID_S1      : 
                      (state_w == M1_S2_w)? BVALID_S2      :
                      (state_w == M1_S3_w)? BVALID_S3      : 
                      (state_w == M1_S4_w)? BVALID_S4      :
                      (state_w == M1_S5_w)? BVALID_S5      :
                      (state_w == M1_S6_w)? BVALID_S6      : 1'd0;

// --- WRITE M2 ---
  assign AWREADY_M2 = (state_w == M2_S1_w)? AWREADY_S1     :
                      (state_w == M2_S2_w)? AWREADY_S2     : 1'b0;

  assign WREADY_M2  = (state_w == M2_S1_w)? WREADY_S1      :
                      (state_w == M2_S2_w)? WREADY_S2      : 1'b0;

  assign BID_M2     = (state_w == M2_S1_w)? BID_S1[3:0]    :
                      (state_w == M2_S2_w)? BID_S2[3:0]    : 4'd0;

  assign BRESP_M2   = (state_w == M2_S1_w)? BRESP_S1       :
                      (state_w == M2_S2_w)? BRESP_S2       : 2'd0;

  assign BVALID_M2  = (state_w == M2_S1_w)? BVALID_S1      :
                      (state_w == M2_S2_w)? BVALID_S2      : 1'b0;                    

// --- WRITE S1 ---
  assign AWID_S1    = (state_w == M1_S1_w)? {4'd0,AWID_M1} :
                      (state_w == M2_S1_w)? {4'd0,AWID_M2} : 8'd0;

	assign AWADDR_S1  = (state_w == M1_S1_w)? AWADDR_M1      : 
                      (state_w == M2_S1_w)? AWADDR_M2      : 32'd0;

	assign AWLEN_S1   = (state_w == M1_S1_w)? AWLEN_M1       : 
                      (state_w == M2_S1_w)? AWLEN_M2       : 4'd0;

	assign AWSIZE_S1  = (state_w == M1_S1_w)? AWSIZE_M1      :
                      (state_w == M2_S1_w)? AWSIZE_M2      : 3'd0;

  
	assign AWBURST_S1 = (state_w == M1_S1_w)? AWBURST_M1     : 
                      (state_w == M2_S1_w)? AWBURST_M2     : 2'd0;

	assign AWVALID_S1 = (state_w == M1_S1_w)? AWVALID_M1     : 
                      (state_w == M2_S1_w)? AWVALID_M2     : 1'd0;

	assign WDATA_S1   = (state_w == M1_S1_w)? WDATA_M1       : 
                      (state_w == M2_S1_w)? WDATA_M2       : 32'd0;

  assign WSTRB_S1   = (state_w == M1_S1_w)? WSTRB_M1       : 
                      (state_w == M2_S1_w)? WSTRB_M2       : {`AXI_STRB_BITS{1'b1}};

  assign WLAST_S1   = (state_w == M1_S1_w)? WLAST_M1       : 
                      (state_w == M2_S1_w)? WLAST_M2       : 1'd0;

  assign WVALID_S1  = (state_w == M1_S1_w)? WVALID_M1      : 
                      (state_w == M2_S1_w)? WVALID_M2      : 1'd0;

  assign BREADY_S1  = (state_w == M1_S1_w)? BREADY_M1      : 
                      (state_w == M2_S1_w)? BREADY_M2      : 1'd0;  

// --- WRITE S2 ---
	assign AWID_S2    = (state_w == M1_S2_w)? {4'd0,AWID_M1} :
                      (state_w == M2_S2_w)? {4'd0,AWID_M2} : 8'd0;

	assign AWADDR_S2  = (state_w == M1_S2_w)? AWADDR_M1      : 
                      (state_w == M2_S2_w)? AWADDR_M2      : 32'd0;

	assign AWLEN_S2   = (state_w == M1_S2_w)? AWLEN_M1       : 
                      (state_w == M2_S2_w)? AWLEN_M2       : 4'd0;

	assign AWSIZE_S2  = (state_w == M1_S2_w)? AWSIZE_M1      :
                      (state_w == M2_S2_w)? AWSIZE_M2      : 3'd0;

  
	assign AWBURST_S2 = (state_w == M1_S2_w)? AWBURST_M1     : 
                      (state_w == M2_S2_w)? AWBURST_M2     : 2'd0;

	assign AWVALID_S2 = (state_w == M1_S2_w)? AWVALID_M1     : 
                      (state_w == M2_S2_w)? AWVALID_M2     : 1'd0;

	assign WDATA_S2   = (state_w == M1_S2_w)? WDATA_M1       : 
                      (state_w == M2_S2_w)? WDATA_M2       : 32'd0;

  assign WSTRB_S2   = (state_w == M1_S2_w)? WSTRB_M1       : 
                      (state_w == M2_S2_w)? WSTRB_M2       : {`AXI_STRB_BITS{1'b1}};

  assign WLAST_S2   = (state_w == M1_S2_w)? WLAST_M1       : 
                      (state_w == M2_S2_w)? WLAST_M2       : 1'd0;

  assign WVALID_S2  = (state_w == M1_S2_w)? WVALID_M1      : 
                      (state_w == M2_S2_w)? WVALID_M2      : 1'd0;

  assign BREADY_S2  = (state_w == M1_S2_w)? BREADY_M1      : 
                      (state_w == M2_S2_w)? BREADY_M2      : 1'd0;  

// --- WRITE S3 ---
  assign AWID_S3    = (state_w == M1_S3_w)? {4'd0,AWID_M1} : 8'd0;
  assign AWADDR_S3  = (state_w == M1_S3_w)? AWADDR_M1      : 32'd0;
  assign AWLEN_S3   = (state_w == M1_S3_w)? AWLEN_M1       : 4'd0;
  assign AWSIZE_S3  = (state_w == M1_S3_w)? AWSIZE_M1      : 3'd0;
  assign AWBURST_S3 = (state_w == M1_S3_w)? AWBURST_M1     : 2'd0;
  assign AWVALID_S3 = (state_w == M1_S3_w)? AWVALID_M1     : 1'b0;
  assign WDATA_S3   = (state_w == M1_S3_w)? WDATA_M1       : 32'd0;
  assign WSTRB_S3   = (state_w == M1_S3_w)? WSTRB_M1       : {`AXI_STRB_BITS{1'b1}};
  assign WLAST_S3   = (state_w == M1_S3_w)? WLAST_M1       : 1'b0;
  assign WVALID_S3  = (state_w == M1_S3_w)? WVALID_M1      : 1'b0;
  assign BREADY_S3  = (state_w == M1_S3_w)? BREADY_M1      : 1'b0;

// --- WRITE S4 ---
  assign AWID_S4    = (state_w == M1_S4_w)? {4'd0,AWID_M1} : 8'd0;
  assign AWADDR_S4  = (state_w == M1_S4_w)? AWADDR_M1      : 32'd0;
  assign AWLEN_S4   = (state_w == M1_S4_w)? AWLEN_M1       : 4'd0;
  assign AWSIZE_S4  = (state_w == M1_S4_w)? AWSIZE_M1      : 3'd0;
  assign AWBURST_S4 = (state_w == M1_S4_w)? AWBURST_M1     : 2'd0;
  assign AWVALID_S4 = (state_w == M1_S4_w)? AWVALID_M1     : 1'b0;
  assign WDATA_S4   = (state_w == M1_S4_w)? WDATA_M1       : 32'd0;
  assign WSTRB_S4   = (state_w == M1_S4_w)? WSTRB_M1       : {`AXI_STRB_BITS{1'b1}};
  assign WLAST_S4   = (state_w == M1_S4_w)? WLAST_M1       : 1'b0;
  assign WVALID_S4  = (state_w == M1_S4_w)? WVALID_M1      : 1'b0;
  assign BREADY_S4  = (state_w == M1_S4_w)? BREADY_M1      : 1'b0;

// --- WRITE S5 ---
  assign AWID_S5    = (state_w == M1_S5_w)? {4'd0,AWID_M1} : 8'd0;
  assign AWADDR_S5  = (state_w == M1_S5_w)? AWADDR_M1      : 32'd0;
  assign AWLEN_S5   = (state_w == M1_S5_w)? AWLEN_M1       : 4'd0;
  assign AWSIZE_S5  = (state_w == M1_S5_w)? AWSIZE_M1      : 3'd0;
  assign AWBURST_S5 = (state_w == M1_S5_w)? AWBURST_M1     : 2'd0;
  assign AWVALID_S5 = (state_w == M1_S5_w)? AWVALID_M1     : 1'b0;
  assign WDATA_S5   = (state_w == M1_S5_w)? WDATA_M1       : 32'd0;
  assign WSTRB_S5   = (state_w == M1_S5_w)? WSTRB_M1       : {`AXI_STRB_BITS{1'b1}};
  assign WLAST_S5   = (state_w == M1_S5_w)? WLAST_M1       : 1'b0;
  assign WVALID_S5  = (state_w == M1_S5_w)? WVALID_M1      : 1'b0;
  assign BREADY_S5  = (state_w == M1_S5_w)? BREADY_M1      : 1'b0;

  // --- WRITE S6 ---
  assign AWID_S6    = (state_w == M1_S6_w)? {4'd0,AWID_M1} : 
                      (state_w == M2_S6_w)? {4'd0,AWID_M2} : 8'd0;
  assign AWADDR_S6  = (state_w == M1_S6_w)? AWADDR_M1      : 
                      (state_w == M2_S6_w)? AWADDR_M2      : 32'd0;
  assign AWLEN_S6   = (state_w == M1_S6_w)? AWLEN_M1       : 
                      (state_w == M2_S6_w)? AWLEN_M2       : 4'd0;
  assign AWSIZE_S6  = (state_w == M1_S6_w)? AWSIZE_M1      :
                      (state_w == M2_S6_w)? AWSIZE_M2      : 3'd0;
  assign AWBURST_S6 = (state_w == M1_S6_w)? AWBURST_M1     : 
                      (state_w == M2_S6_w)? AWBURST_M2     : 2'd0;
  assign AWVALID_S6 = (state_w == M1_S6_w)? AWVALID_M1     : 
                      (state_w == M2_S6_w)? AWVALID_M2     : 1'b0;
  assign WDATA_S6   = (state_w == M1_S6_w)? WDATA_M1       : 
                      (state_w == M2_S6_w)? WDATA_M2       : 32'd0;
  assign WSTRB_S6   = (state_w == M1_S6_w)? WSTRB_M1       : 
                      (state_w == M2_S6_w)? WSTRB_M2       : {`AXI_STRB_BITS{1'b1}};
  assign WLAST_S6   = (state_w == M1_S6_w)? WLAST_M1       : 
                      (state_w == M2_S6_w)? WLAST_M2       : 1'b0;
  assign WVALID_S6  = (state_w == M1_S6_w)? WVALID_M1      : 
                      (state_w == M2_S6_w)? WVALID_M2      : 1'b0;
  assign BREADY_S6  = (state_w == M1_S6_w)? BREADY_M1      : 
                      (state_w == M2_S6_w)? BREADY_M2      : 1'b0;
                      
endmodule 