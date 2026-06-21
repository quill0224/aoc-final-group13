`include "AXI/AXI_define.svh"
`include "ASIC.svh"

// =============================================================================
// integration.sv — Sub-system Integration Wrapper
// Integrates Controller, DMA, MC, GLB, and AXI Memory Model.
// =============================================================================

module integration (
    input  logic                                clk,
    input  logic                                rst,

    input  logic                                asic_en,
    output logic                                asic_done,

    // -------------------------------------------------------------------------
    // [UPDATED] Unified 32-bit Command Interface (Replaces M/K/N_tiles_in)
    // -------------------------------------------------------------------------
    input  logic [31:0]                         asic_cmd_in,

    // MMIO Parameters (Base Addresses & Lengths)
    input  logic [`AXI_ADDR_BITS-1:0]           A_fiber_base_addr,
    input  logic [`AXI_ADDR_BITS-1:0]           B_fiber_base_addr,
    input  logic [`AXI_ADDR_BITS-1:0]           C_tensor_base_addr,
    input  logic [`GLB_ADDR_BITS-1:0]           GLB_A_base_addr,
    input  logic [`GLB_ADDR_BITS-1:0]           GLB_B_base_addr,
    input  logic [`GLB_ADDR_BITS-1:0]           GLB_C_base_addr,
    input  logic [31:0]                         comp_A_len_in,
    input  logic [31:0]                         comp_B_len_in,
    input  logic [31:0]                         comp_C_len_in,
    
    // PE Mapping
    input  logic [3:0]                          e,
    input  logic [2:0]                          p,
    input  logic [2:0]                          q,

    // Downstream Mock Signals
    input  logic                                PEA_A_ready,
    input  logic                                PEA_B_ready,
    input  logic                                ppu_done,
    
    // -------------------------------------------------------------------------
    // Observation Ports (For C++ Testbench & Mock PE)
    // -------------------------------------------------------------------------
    output logic                                obs_mc_start,
    output logic                                obs_global_flush,

    // [PE Config Channel]
    output logic                                obs_pe_cfg_valid,
    input  logic                                mock_pe_cfg_ready, 
    output logic [15:0]                         obs_pe_cfg_length,
    output logic [15:0]                         obs_pe_cfg_bitmask,

    // [PE Data Channel]
    output logic                                obs_pe_data_valid,
    input  logic                                mock_pe_data_ready, 
    output logic [31:0]                         obs_pe_data_nzvalue
);

    // =========================================================================
    // Dummy Wires (To suppress Verilator PINCONNECTEMPTY warnings)
    // =========================================================================
    wire [`PE_ARRAY_H*`PE_ARRAY_W-1:0]          dummy_PE_en;
    wire [10:0]                                 dummy_PE_config;
    wire                                        dummy_set_XID, dummy_set_YID, dummy_set_LN;
    wire [`XID_BITS-1:0]                        dummy_scan_XID_ifmap, dummy_scan_XID_filter, dummy_scan_XID_ipsum, dummy_scan_XID_opsum;
    wire [`YID_BITS-1:0]                        dummy_scan_YID_ifmap, dummy_scan_YID_filter, dummy_scan_YID_ipsum, dummy_scan_YID_opsum;
    wire [`PE_ARRAY_H-2:0]                      dummy_LN_config;
    wire                                        dummy_PEA_opsum_ready;
    wire [`XID_BITS-1:0]                        dummy_opsum_tag_X, dummy_opsum_tag_Y;
    wire                                        dummy_relu_sel, dummy_Maxpool_en, dummy_Maxpool_init;

    // =========================================================================
    // Internal Wiring
    // =========================================================================
    
    // Controller <-> DMA
    logic                                       dma_en, dma_done;
    logic [1:0]                                 dma_mode;
    logic [`AXI_ADDR_BITS-1:0]                  dma_dram_addr;
    logic [`GLB_ADDR_BITS-1:0]                  dma_glb_addr;
    logic [31:0]                                dma_len;

    // Controller <-> MC
    logic                                       mc_start, k_done;
    logic [1:0]                                 mc_mode;
    logic [`GLB_ADDR_BITS-1:0]                  mc_glb_base_A, mc_glb_base_B;
    logic [`PKT_CNT_BITS-1:0]                   mc_packet_count;

    // MC <-> GLB (MC Dedicated Read Bus)
    logic                                       mc_glb_ren_A, mc_glb_ren_B;
    logic [`GLB_ADDR_BITS-1:0]                  mc_glb_addr_A, mc_glb_addr_B;

    // [Iris] MC egress 內部線:同時餵 pe_entry 與 tap 給 obs_*
    logic                                       mc_pe_cfg_valid, mc_pe_data_valid;
    logic [15:0]                                mc_pe_cfg_length, mc_pe_cfg_bitmask;
    logic [31:0]                                mc_pe_data_nzvalue;
    logic                                       pe_cfg_ready_w, pe_data_ready_w;   // pe_entry → MC
    // [Iris] pe_entry → 下游 A/B buffer(尚未接;先拉出供觀察)
    logic [15:0]                                pe_out_bitmask;
    logic [15:0][7:0]                           pe_out_nz;
    logic [4:0]                                 pe_out_len;
    logic                                       pe_out_side, pe_out_valid;
    logic [3:0]                                 pe_out_idx;

    // [Iris] controller→pe_array 控制線 + pe_array 輸出(取代裸 pe_entry)
    logic [1:0]                                 pe_mode_w;        // = controller.global_mode
    logic                                       pe_first_pass_w;  // = controller.pe_first_pass
    logic [8:0]                                 pe_cur_n_base_w;  // = controller.pe_cur_n_base (LOCAL_BUF_AW=9)
    logic                                       pe_compute_done_w;
    logic signed [15:0][31:0]                   pe_c_out_w;       // [N_PE_ROW-1:0][ACC_W-1:0]
    logic                                       pe_c_valid_w;

    // DMA <-> GLB & AXI
    logic                                       glb_en, glb_we;
    logic [3:0]                                 glb_wstrb;
    logic [`GLB_ADDR_BITS-1:0]                  glb_addr;
    logic [31:0]                                glb_wdata, glb_rdata;

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
    // GLB Access Arbiter (MC Read Priority)
    // =========================================================================
    logic                                       mux_glb_en;
    logic                                       mux_glb_we;
    logic [`GLB_ADDR_BITS-1:0]                  mux_glb_addr;

    always_comb begin
        if (mc_glb_ren_A) begin
            // MC takes over GLB Address Bus for Channel A
            mux_glb_en   = 1'b1;
            mux_glb_we   = 1'b0;            // MC only has read permission
            mux_glb_addr = mc_glb_addr_A;
        end else begin
            // Default to DMA control
            mux_glb_en   = glb_en;
            mux_glb_we   = glb_we;
            mux_glb_addr = glb_addr;
        end
    end

    // =========================================================================
    // Module Instantiations
    // =========================================================================

    controller u_ctrl (
        .clk                    (clk), 
        .rst                    (rst), 
        .asic_en                (asic_en), 
        .asic_done              (asic_done),
        
        // ---------------------------------------------------------------------
        // [UPDATED] Bind to 32-bit Command Port
        // ---------------------------------------------------------------------
        .asic_cmd_in            (asic_cmd_in),
        // ---------------------------------------------------------------------

        .A_fiber_base_addr      (A_fiber_base_addr), 
        .B_fiber_base_addr      (B_fiber_base_addr),
        .C_tensor_base_addr     (C_tensor_base_addr), 
        .GLB_A_base_addr        (GLB_A_base_addr),
        .GLB_B_base_addr        (GLB_B_base_addr), 
        .GLB_C_base_addr        (GLB_C_base_addr),
        
        .comp_A_len_in          (comp_A_len_in), 
        .comp_B_len_in          (comp_B_len_in), 
        .comp_C_len_in          (comp_C_len_in),
        
        .e(e), .p(p), .q(q), .r(3'b0), .t(3'b0),
        
        .DMA_en                 (dma_en), 
        .DMA_mode               (dma_mode), 
        .DMA_DRAM_ADDR          (dma_dram_addr), 
        .DMA_GLB_ADDR           (dma_glb_addr), 
        .DMA_len                (dma_len), 
        .DMA_done               (dma_done),
        
        .mc_start               (mc_start), 
        .mc_mode                (mc_mode), 
        .mc_glb_base_A          (mc_glb_base_A), 
        .mc_glb_base_B          (mc_glb_base_B),
        .mc_packet_count        (mc_packet_count), 
        .k_done                 (k_done),
        
        .global_mode            (pe_mode_w),
        .global_flush           (obs_global_flush),
        .pe_first_pass          (pe_first_pass_w),
        .pe_cur_n_base          (pe_cur_n_base_w),
        .PE_en                  (dummy_PE_en), 
        .PE_config              (dummy_PE_config), 
        .PEA_A_ready            (PEA_A_ready), 
        .PEA_B_ready            (PEA_B_ready),
        .set_XID                (dummy_set_XID), 
        .set_YID                (dummy_set_YID), 
        .set_LN                 (dummy_set_LN), 
        .ifmap_XID_scan_in      (dummy_scan_XID_ifmap), 
        .filter_XID_scan_in     (dummy_scan_XID_filter),
        .ipsum_XID_scan_in      (dummy_scan_XID_ipsum), 
        .opsum_XID_scan_in      (dummy_scan_XID_opsum), 
        .ifmap_YID_scan_in      (dummy_scan_YID_ifmap), 
        .filter_YID_scan_in     (dummy_scan_YID_filter),
        .ipsum_YID_scan_in      (dummy_scan_YID_ipsum), 
        .opsum_YID_scan_in      (dummy_scan_YID_opsum), 
        .LN_config_in           (dummy_LN_config),
        .PEA_opsum_valid        (1'b0), 
        .PEA_opsum_ready        (dummy_PEA_opsum_ready), 
        .opsum_tag_X            (dummy_opsum_tag_X), 
        .opsum_tag_Y            (dummy_opsum_tag_Y),
        .relu_sel               (dummy_relu_sel), 
        .Maxpool_en             (dummy_Maxpool_en), 
        .Maxpool_init           (dummy_Maxpool_init), 
        .ppu_done               (ppu_done)
    );

    MC u_mc (
        .clk                    (clk),
        .rst                    (rst),
        .mc_start               (mc_start),
        .mc_mode                (mc_mode),
        .mc_glb_base_A          (mc_glb_base_A),
        .mc_glb_base_B          (mc_glb_base_B),
        .mc_packet_count        (mc_packet_count),
        .k_done                 (k_done),
        
        // MC to GLB Arbitrated Bus
        .mc_glb_ren_A           (mc_glb_ren_A),        
        .mc_glb_addr_A          (mc_glb_addr_A), 
        .glb_rdata_A            (glb_rdata),            
        
        .mc_glb_ren_B           (mc_glb_ren_B), 
        .mc_glb_addr_B          (mc_glb_addr_B),
        
        // [Iris] un-mock:egress 改接內部線,ready 改由 pe_entry 驅動(原本接 obs_/mock_)
        .pe_cfg_valid           (mc_pe_cfg_valid),
        .pe_cfg_ready           (pe_cfg_ready_w),
        .pe_cfg_length          (mc_pe_cfg_length),
        .pe_cfg_bitmask         (mc_pe_cfg_bitmask),

        .pe_data_valid          (mc_pe_data_valid),
        .pe_data_ready          (pe_data_ready_w),
        .pe_data_nzvalue        (mc_pe_data_nzvalue)
    );

    // [Iris] 把裸 pe_entry 換成 pe_array(內含 pe_entry + pe_ab_buffer + 16×pe_row)。
    //   MC egress 與原 pe_entry 完全相同接法 → MC→(內部 pe_entry) 行為不變;
    //   dbg_ent_* 透出內部 pe_entry 輸出 → 沿用原 pe_out_* DEBUG;
    //   controller mode/first_pass/cur_n_base 接上;dump 暫綁 0(掃描邏輯未做);
    //   pe_compute_done / c_out 先觀察(controller S6 握手 + dump 掃描待後續)。
    pe_array u_pe_array (
        .clk            (clk),
        .rst_n          (~rst),
        // MC egress(與原 pe_entry 相同)
        .pe_cfg_valid   (mc_pe_cfg_valid),
        .pe_cfg_ready   (pe_cfg_ready_w),
        .pe_cfg_length  (mc_pe_cfg_length),
        .pe_cfg_bitmask (mc_pe_cfg_bitmask),
        .pe_data_valid  (mc_pe_data_valid),
        .pe_data_ready  (pe_data_ready_w),
        .pe_data_nzvalue(mc_pe_data_nzvalue),
        // controller 控制
        .mode           (pe_mode_w),
        .first_pass     (pe_first_pass_w),
        .cur_n_base     (pe_cur_n_base_w),
        .dump_en        (1'b0),
        .dump_addr      (9'd0),
        .pe_compute_done(pe_compute_done_w),
        .c_out          (pe_c_out_w),
        .c_valid        (pe_c_valid_w),
        // 觀察 tap(沿用原 pe_out_* DEBUG)
        .dbg_ent_bitmask(pe_out_bitmask),
        .dbg_ent_nz     (pe_out_nz),
        .dbg_ent_len    (pe_out_len),
        .dbg_ent_side   (pe_out_side),
        .dbg_ent_idx    (pe_out_idx),
        .dbg_ent_valid  (pe_out_valid)
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
        .clk(clk), .rst(rst), .EN(mux_glb_en), .WEB(~mux_glb_we),
        .WSTRB(glb_wstrb), .A(mux_glb_addr), .DI(glb_wdata), .DO(glb_rdata)
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

    // Observations
    assign obs_mc_start        = mc_start;
    // [Iris] obs_pe_* 仍反映 MC egress(C TB trace 用),只是改從內部線 tap
    assign obs_pe_cfg_valid    = mc_pe_cfg_valid;
    assign obs_pe_cfg_length   = mc_pe_cfg_length;
    assign obs_pe_cfg_bitmask  = mc_pe_cfg_bitmask;
    assign obs_pe_data_valid   = mc_pe_data_valid;
    assign obs_pe_data_nzvalue = mc_pe_data_nzvalue;

    // [Iris] mock_pe_*_ready 已被 pe_array 內部 pe_entry 取代,僅 sink 避免 unused 警告
    wire _unused_mock = &{1'b0, mock_pe_cfg_ready, mock_pe_data_ready};
    // [Iris] pe_array 輸出暫未接(compute_done 握手 / dump 讀出待後續)→ sink
    wire _unused_pa   = &{1'b0, pe_compute_done_w, pe_c_valid_w, pe_c_out_w};

    // [Iris] DEBUG(sim-only):印出 pe_entry 真正組好的 fiber → 確認 A(side=0)/B(side=1) 都進來
    always_ff @(posedge clk) begin
        if (pe_out_valid)
            $display("[PE_ENTRY @%0t] side=%0d idx=%0d len=%0d bm=0x%04h nz0=0x%02h",
                     $time, pe_out_side, pe_out_idx, pe_out_len, pe_out_bitmask, pe_out_nz[0]);
    end

endmodule
