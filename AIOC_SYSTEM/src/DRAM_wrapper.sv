module DRAM_wrapper(

	input clk,rst,
	//WRITE ADDRESS
	input [`AXI_IDS_BITS-1:0] AWID,
	input [`AXI_ADDR_BITS-1:0] AWADDR,
	input [3:0]				   AWLEN,
	input [`AXI_SIZE_BITS-1:0] AWSIZE,
	input [1:0] AWBURST,
	input AWVALID,
	output logic AWREADY,
	
	//WRITE DATA5
	input [`AXI_DATA_BITS-1:0] WDATA,
	input [`AXI_STRB_BITS-1:0] WSTRB,
	input WLAST,
	input WVALID,
	output logic WREADY,
	
	//WRITE RESPONSE5
	output logic [`AXI_IDS_BITS-1:0] BID,
	output logic [1:0] BRESP,
	output logic BVALID,
	input BREADY,
	
	//READ ADDRESS
	input [`AXI_IDS_BITS-1:0] ARID,
	input [`AXI_ADDR_BITS-1:0] ARADDR,
	input [3:0] 			   ARLEN,
	input [`AXI_SIZE_BITS-1:0] ARSIZE,
	input [1:0] ARBURST,
	input ARVALID,
	output logic ARREADY,
	
	//READ DATA5
	output [7:0] RID,
	output [31:0] RDATA,
	output [1:0] RRESP,
	output RLAST,
	output RVALID,
	input logic RREADY,
	
	//DRAM Control
	input VALID,
    input [31:0]Q,
	output logic CSn,
    output logic [3:0]WEn,
    output logic RASn,
    output logic CASn,
    output logic [10:0]A,
    output logic [31:0]D
);

	DRAM_FSM DRAM_Control(
	.ACLK(clk),
	.ARESETn(rst),
	.AWID(AWID),
	.AWADDR(AWADDR),
	.AWLEN(AWLEN),
	.AWSIZE(AWSIZE),
	.AWBURST(AWBURST),
	.AWVALID(AWVALID),
	.AWREADY(AWREADY),
	.WDATA(WDATA),
	.WSTRB(~WSTRB),
	.WLAST(WLAST),
	.WVALID(WVALID),
	.WREADY(WREADY),
	.BID(BID),
	.BRESP(BRESP),
	.BVALID(BVALID),
	.BREADY(BREADY),
	.ARID(ARID),
	.ARADDR(ARADDR),
	.ARLEN(ARLEN),
	.ARSIZE(ARSIZE),
	.ARBURST(ARBURST),
	.ARVALID(ARVALID),
	.ARREADY(ARREADY),
	.RID(RID),
	.RDATA(RDATA),
	.RRESP(RRESP),
	.RLAST(RLAST),
	.RVALID(RVALID),
	.RREADY(RREADY),
	.CSn(CSn),
	.WEn(WEn),
	.RASn(RASn),
	.CASn(CASn),
	.A(A),
	.D(D),
	.Q(Q),
	.VALID(VALID)
);

endmodule