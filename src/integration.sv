`include "AXI/AXI_define.svh"
`include "ASIC.svh"

// =============================================================================
// integration.sv — Sub-system Integration Wrapper (Controller + DMA + MC + GLB)
// =============================================================================

module integration (
    input  logic                                clk,
    input  logic                                rst,

    input  logic                                asic_en,
    output logic                                asic_done,

    // MMIO Parameters
    input  logic [`AXI_ADDR_BITS-1:0]           A_fiber_base_addr,
    input  logic [`AXI_ADDR_BITS-1:0]           B_fiber_base_addr,
    input  logic [`AXI_ADDR_BITS-1:0]           C_tensor_base_addr,
    input  logic [`GLB_ADDR_BITS-1:0]           GLB_A_base_addr,
    input  logic [`GLB_ADDR_BITS-1:0]           GLB_B_base_addr,
    input  logic [`GLB_ADDR_BITS-1:0]           GLB_C_base_addr,
    input  logic [31:0]                         comp_A_len_in,
    input  logic [31:0]                         comp_B_len_in,
    input  logic [31:0]                         comp_C_len_in,
    input  logic [`N_CNT_BITS-1:0]              N_tiles_in,
    input  logic [`K_CNT_BITS-1:0]              K_tiles_in,
    input  logic [`M_CNT_BITS-1:0]              M_tiles_in,
    input  logic [`PKT_CNT_BITS-1:0]            packet_count_in,
    input  logic [1:0]                          operation_mode_in,
    input  logic [3:0]                          e,
    input  logic [2:0]                          p,
    input  logic [2:0]                          q,

    // 下游 Mock 訊號 (PE Array / PPU 尚未加入)
    input  logic                                PEA_A_ready,
    input  logic                                PEA_B_ready,
    input  logic                                ppu_done,
    
    // 觀測腳位 (供 C++ Testbench 監聽)
    output logic                                obs_mc_start,
    output logic                                obs_pe_data_valid,
    output logic                                obs_global_flush
);

    // =========================================================================
    // 內部接線邏輯
    // =========================================================================
    
    // Controller <-> DMA
    logic                             dma_en, dma_done;
    logic [1:0]                       dma_mode;
    logic [`AXI_ADDR_BITS-1:0]        dma_dram_addr;
    logic [`GLB_ADDR_BITS-1:0]        dma_glb_addr;
    logic [31:0]                      dma_len;

    // Controller <-> MC
    logic                             mc_start, k_done;
    logic [1:0]                       mc_mode;
    logic [`GLB_ADDR_BITS-1:0]        mc_glb_base_A, mc_glb_base_B;
    logic [`PKT_CNT_BITS-1:0]         mc_packet_count;

    // DMA <-> GLB & AXI
    logic                             glb_en, glb_we;
    logic [3:0]                       glb_wstrb;
    logic [`GLB_ADDR_BITS-1:0]        glb_addr;
    logic [31:0]                      glb_wdata, glb_rdata;

    logic [`AXI_ID_BITS-1:0]   arid, awid, rid, bid;
    logic [`AXI_ADDR_BITS-1:0] araddr, awaddr;
    logic [`AXI_LEN_BITS-1:0]  arlen, awlen;
    logic [`AXI_SIZE_BITS-1:0] arsize, awsize;
    logic [1:0]                arburst, awburst, rresp, bresp;
    logic                      arvalid, arready, rlast, rvalid, rready;
    logic                      awvalid, awready, wlast, wvalid, wready, bvalid, bready;
    logic [`AXI_DATA_BITS-1:0] rdata, wdata;
    logic [`AXI_STRB_BITS-1:0] wstrb;

    // =========================================================================
    // 子模組實體化 (徹底移除所有的 top_ 前綴)
    // =========================================================================

    controller u_ctrl (
        .clk(clk), .rst(rst), .asic_en(asic_en), .asic_done(asic_done),
        .A_fiber_base_addr(A_fiber_base_addr), .B_fiber_base_addr(B_fiber_base_addr),
        .C_tensor_base_addr(C_tensor_base_addr), .GLB_A_base_addr(GLB_A_base_addr),
        .GLB_B_base_addr(GLB_B_base_addr), .GLB_C_base_addr(GLB_C_base_addr),
        .comp_A_len_in(comp_A_len_in), .comp_B_len_in(comp_B_len_in), .comp_C_len_in(comp_C_len_in),
        .N_tiles_in(N_tiles_in), .K_tiles_in(K_tiles_in), .M_tiles_in(M_tiles_in),
        .packet_count_in(packet_count_in), .operation_mode_in(operation_mode_in),
        .e(e), .p(p), .q(q), .r(3'b0), .t(3'b0),
        
        .DMA_en(dma_en), .DMA_mode(dma_mode), .DMA_DRAM_ADDR(dma_dram_addr), 
        .DMA_GLB_ADDR(dma_glb_addr), .DMA_len(dma_len), .DMA_done(dma_done),
        
        .mc_start(mc_start), .mc_mode(mc_mode), 
        .mc_glb_base_A(mc_glb_base_A), .mc_glb_base_B(mc_glb_base_B),
        .mc_packet_count(mc_packet_count), .k_done(k_done),
        
        .global_mode(), .global_flush(obs_global_flush),
        .PE_en(), .PE_config(), .PEA_A_ready(PEA_A_ready), .PEA_B_ready(PEA_B_ready),
        .set_XID(), .set_YID(), .set_LN(), .ifmap_XID_scan_in(), .filter_XID_scan_in(),
        .ipsum_XID_scan_in(), .opsum_XID_scan_in(), .ifmap_YID_scan_in(), .filter_YID_scan_in(),
        .ipsum_YID_scan_in(), .opsum_YID_scan_in(), .LN_config_in(),
        .PEA_opsum_valid(1'b0), .PEA_opsum_ready(), .opsum_tag_X(), .opsum_tag_Y(),
        .relu_sel(), .Maxpool_en(), .Maxpool_init(), .ppu_done(ppu_done)
    );

    MC u_mc (
        .clk(clk),
        .rst(rst),
        .mc_start(mc_start),
        .mc_mode(mc_mode),
        .mc_glb_base_A(mc_glb_base_A),
        .mc_glb_base_B(mc_glb_base_B),
        .mc_packet_count(mc_packet_count),
        .k_done(k_done),
        .mc_glb_ren_A(),        
        .mc_glb_addr_A(), 
        .mc_glb_ren_B(), 
        .mc_glb_addr_B(),
        .pe_data_valid(obs_pe_data_valid)
    );

    DMA u_dma (
        .clk(clk), .rst(rst), .DMA_en(dma_en), .DMA_mode(dma_mode), 
        .DMA_DRAM_ADDR(dma_dram_addr), .DMA_GLB_ADDR(dma_glb_addr), .DMA_len(dma_len), 
        .DMA_done(dma_done), .glb_en(glb_en), .glb_we(glb_we), .glb_wstrb(glb_wstrb), 
        .glb_addr(glb_addr), .glb_wdata(glb_wdata), .glb_rdata(glb_rdata),
        .ARID(arid), .ARADDR(araddr), .ARLEN(arlen), .ARSIZE(arsize), .ARBURST(arburst), 
        .ARVALID(arvalid), .ARREADY(arready), .RID(rid), .RDATA(rdata), .RRESP(rresp), 
        .RLAST(rlast), .RVALID(rvalid), .RREADY(rready), .AWID(awid), .AWADDR(awaddr), 
        .AWLEN(awlen), .AWSIZE(awsize), .AWBURST(awburst), .AWVALID(awvalid), 
        .AWREADY(awready), .WDATA(wdata), .WSTRB(wstrb), .WLAST(wlast), .WVALID(wvalid), 
        .WREADY(wready), .BID(bid), .BRESP(bresp), .BVALID(bvalid), .BREADY(bready)
    );

    GLB u_glb (
        .clk(clk), .rst(rst), .EN(glb_en), .WEB(~glb_we),
        .WSTRB(glb_wstrb), .A(glb_addr), .DI(glb_wdata), .DO(glb_rdata)
    );

    axi_mem_model u_dram (
        .clk(clk), .rst(rst), .ARID(arid), .ARADDR(araddr), .ARLEN(arlen), 
        .ARSIZE(arsize), .ARBURST(arburst), .ARVALID(arvalid), .ARREADY(arready), 
        .RID(rid), .RDATA(rdata), .RRESP(rresp), .RLAST(rlast), .RVALID(rvalid), 
        .RREADY(rready), .AWID(awid), .AWADDR(awaddr), .AWLEN(awlen), .AWSIZE(awsize), 
        .AWBURST(awburst), .AWVALID(awvalid), .AWREADY(awready), .WDATA(wdata), 
        .WSTRB(wstrb), .WLAST(wlast), .WVALID(wvalid), .WREADY(wready), .BID(bid), 
        .BRESP(bresp), .BVALID(bvalid), .BREADY(bready)
    );

    // 觀測點
    assign obs_mc_start = mc_start;

endmodule
