`include "AXI/AXI_define.svh"
`include "ASIC.svh"

// =============================================================================
// controller.sv — Command-Driven Trapezoid-Lite ASIC FSM
//
// Dataflow: Input Stationary (IS)
// Loop Order: M (Spatial) -> K (Input Ch) -> N (Output Ch)
// 
// 運作邏輯:
// 1. Fetch A(m,k) 進入 SRAM (固定)
// 2. Fetch B(k,n) 進入 SRAM (滑動 N)
// 3. 觸發 MC 進行 MAC 運算
// 4. 重複 2-3 直到 N 結束 (完成一個 K 通道的計算)
// 5. N 結束後，更新 K，回到 1 抓下一組 A 與 B (Psum 在 SRAM 內累加)
// 6. K 結束後，該 M_Tile 的 Psum 累積完成 -> 觸發 global_flush 交給 PPU
// =============================================================================

module controller (
    input  logic                                clk,
    input  logic                                rst,
    input  logic                                asic_en,       
    output logic                                asic_done,     

    // [修改] 單一 32-bit Command 介面取代多個獨立腳位
    input  logic [31:0]                         asic_cmd_in,

    input  logic [`AXI_ADDR_BITS-1:0]           A_fiber_base_addr,
    input  logic [`AXI_ADDR_BITS-1:0]           B_fiber_base_addr,
    input  logic [`AXI_ADDR_BITS-1:0]           C_tensor_base_addr,

    input  logic [`GLB_ADDR_BITS-1:0]           GLB_A_base_addr,
    input  logic [`GLB_ADDR_BITS-1:0]           GLB_B_base_addr,
    input  logic [`GLB_ADDR_BITS-1:0]           GLB_C_base_addr,

    input  logic [31:0]                         comp_A_len_in,
    input  logic [31:0]                         comp_B_len_in,
    input  logic [31:0]                         comp_C_len_in,

    input  logic [3:0]                          e,
    input  logic [2:0]                          p,
    input  logic [2:0]                          q,    
    input  logic [2:0]                          r,    
    input  logic [2:0]                          t,    

    output logic                                DMA_en,
    output logic [1:0]                          DMA_mode,
    output logic [`AXI_ADDR_BITS-1:0]           DMA_DRAM_ADDR,
    output logic [`GLB_ADDR_BITS-1:0]           DMA_GLB_ADDR,
    output logic [31:0]                         DMA_len,
    input  logic                                DMA_done,      

    output logic                                mc_start,      
    output logic [1:0]                          mc_mode,
    output logic [`GLB_ADDR_BITS-1:0]           mc_glb_base_A,
    output logic [`GLB_ADDR_BITS-1:0]           mc_glb_base_B,
    output logic [`PKT_CNT_BITS-1:0]            mc_packet_count,
    input  logic                                k_done,
    input  logic                                pe_tile_done,   // PE 算完一個 tile(整合用;case_CTRL 已 stale 不編)

    output logic [1:0]                          global_mode,
    output logic                                global_flush,
    // → pe_row_tail (B-3) 控制:第一個 K-tile 覆寫、本 N-tile 基底欄
    output logic                                pe_first_pass,
    output logic [8:0]                          pe_cur_n_base,   // = LOCAL_BUF_AW 寬 (512 深)
    output logic [`PE_ARRAY_H*`PE_ARRAY_W-1:0]  PE_en,
    output logic [10:0]                         PE_config,    
    input  logic                                PEA_A_ready,
    input  logic                                PEA_B_ready,

    output logic                                set_XID,
    output logic                                set_YID,
    output logic                                set_LN,
    output logic [`XID_BITS-1:0]                ifmap_XID_scan_in,
    output logic [`XID_BITS-1:0]                filter_XID_scan_in,
    output logic [`XID_BITS-1:0]                ipsum_XID_scan_in,
    output logic [`XID_BITS-1:0]                opsum_XID_scan_in,
    output logic [`YID_BITS-1:0]                ifmap_YID_scan_in,
    output logic [`YID_BITS-1:0]                filter_YID_scan_in,
    output logic [`YID_BITS-1:0]                ipsum_YID_scan_in,
    output logic [`YID_BITS-1:0]                opsum_YID_scan_in,
    output logic [`PE_ARRAY_H-2:0]              LN_config_in,

    input  logic                                PEA_opsum_valid,  
    output logic                                PEA_opsum_ready,
    output logic [`XID_BITS-1:0]                opsum_tag_X,
    output logic [`YID_BITS-1:0]                opsum_tag_Y,
    output logic                                relu_sel,
    output logic                                Maxpool_en,
    output logic                                Maxpool_init,
    input  logic                                ppu_done
);

    // =========================================================================
    // FSM States (IS Dataflow: M -> K -> N)
    // =========================================================================
    typedef enum logic [3:0] {
        S0_IDLE           = 4'd0,
        S1_SHADOW_LATCH   = 4'd1,
        S2_DMA_FETCH_A    = 4'd2,   // Fetch IFMAP (Stationary during N loop)
        S3_DMA_FETCH_B    = 4'd3,   // Fetch Filter (Streams across N loop)
        S4_SEND_PE_CONFIG = 4'd4,   
        S5_MC_DISPATCH    = 4'd5,   
        S6_WAIT_K_DONE    = 4'd6,
        S6B_WAIT_PE       = 4'd14,  // 等 PE 算完此 tile 再推進(避免覆寫 pe_ab_buffer)
        S7_UPDATE_N       = 4'd7,   // Check N loop (Inner)
        S8_UPDATE_K       = 4'd8,   // Check K loop (Middle)
        S9_FLUSH          = 4'd9,   // K loop done -> Psum complete -> Flush
        S10_WAIT_PPU      = 4'd10,  
        S11_DMA_WRITEBACK = 4'd11,  
        S12_UPDATE_M      = 4'd12,  // Check M loop (Outer)
        S13_DONE          = 4'd13
    } state_t;

    state_t cs, ns;

    // =========================================================================
    // Shadow Registers & Hardware Command Decoding
    // =========================================================================
    logic [31:0]               comp_A_len, comp_B_len, comp_C_len;
    logic [`N_CNT_BITS-1:0]    N_tiles;
    logic [`K_CNT_BITS-1:0]    K_tiles;
    logic [`M_CNT_BITS-1:0]    M_tiles;
    logic [`PKT_CNT_BITS-1:0]  packet_count;
    logic [1:0]                operation_mode;
    logic [`GLB_ADDR_BITS-1:0] GLB_A_base, GLB_B_base, GLB_C_base;

    wire [`M_CNT_BITS-1:0]     cmd_m_val   = asic_cmd_in[`CMD_M_MSB : `CMD_M_LSB];
    wire [`K_CNT_BITS-1:0]     cmd_k_val   = asic_cmd_in[`CMD_K_MSB : `CMD_K_LSB];
    wire [`N_CNT_BITS-1:0]     cmd_n_val   = asic_cmd_in[`CMD_N_MSB : `CMD_N_LSB];
    wire [`PKT_CNT_BITS-1:0]   cmd_pkt_val = asic_cmd_in[`CMD_PKT_MSB : `CMD_PKT_LSB];

    // Counters
    logic [`N_CNT_BITS-1:0]    n_cnt;
    logic [`K_CNT_BITS-1:0]    k_cnt;
    logic [`M_CNT_BITS-1:0]    m_cnt;

    // Address Accumulators
    logic [31:0] addr_acc_A;
    logic [31:0] addr_acc_B;
    logic [31:0] addr_acc_C;

    logic dma_a_done_flag, dma_b_done_flag, dma_wb_done_flag;

    always_ff @(posedge clk) begin
        if (rst || cs == S0_IDLE) begin
            dma_a_done_flag  <= 1'b0;
            dma_b_done_flag  <= 1'b0;
            dma_wb_done_flag <= 1'b0;
        end else begin
            if      (cs == S2_DMA_FETCH_A && DMA_done) dma_a_done_flag <= 1'b1;
            else if (cs == S3_DMA_FETCH_B)             dma_a_done_flag <= 1'b0;

            if      (cs == S3_DMA_FETCH_B && DMA_done) dma_b_done_flag <= 1'b1;
            else if (cs == S4_SEND_PE_CONFIG)          dma_b_done_flag <= 1'b0;

            if      (cs == S11_DMA_WRITEBACK && DMA_done) dma_wb_done_flag <= 1'b1;
            else if (cs == S12_UPDATE_M)                  dma_wb_done_flag <= 1'b0;
        end
    end

    (* async_reg = "TRUE" *) logic asic_en_sync1, asic_en_sync;
    always_ff @(posedge clk) begin
        if (rst) begin
            asic_en_sync1 <= 1'b0;
            asic_en_sync  <= 1'b0;
        end else begin
            asic_en_sync1 <= asic_en;
            asic_en_sync  <= asic_en_sync1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) cs <= S0_IDLE;
        else     cs <= ns;
    end

    // =========================================================================
    // FSM State Transitions
    // =========================================================================
    always_comb begin
        ns = cs;
        case (cs)
            S0_IDLE: begin
                if (asic_en_sync) ns = S1_SHADOW_LATCH;
            end
            S1_SHADOW_LATCH: begin
                ns = S2_DMA_FETCH_A;
            end
            S2_DMA_FETCH_A: begin
                if (dma_a_done_flag) ns = S3_DMA_FETCH_B;
            end
            S3_DMA_FETCH_B: begin
                if (dma_b_done_flag && PEA_A_ready && PEA_B_ready)
                    ns = S4_SEND_PE_CONFIG;
            end
            S4_SEND_PE_CONFIG: begin
                ns = S5_MC_DISPATCH;
            end
            S5_MC_DISPATCH: begin
                ns = S6_WAIT_K_DONE;
            end
            S6_WAIT_K_DONE: begin
                if (k_done) ns = S6B_WAIT_PE;
            end
            S6B_WAIT_PE: begin
                if (pe_tile_done) ns = S7_UPDATE_N;   // 等 PE 真的算完才換下一個 tile
            end
            S7_UPDATE_N: begin
                if (n_cnt < N_tiles - 1) ns = S3_DMA_FETCH_B; // N 未完，滑動 B
                else                     ns = S8_UPDATE_K;    // N 完結，切換 K
            end
            S8_UPDATE_K: begin
                if (k_cnt < K_tiles - 1) ns = S2_DMA_FETCH_A; // K 未完，重新抓 A 與 B
                else                     ns = S9_FLUSH;       // K 完結，Psum 累積完成
            end
            S9_FLUSH: begin
                ns = S10_WAIT_PPU;
            end
            S10_WAIT_PPU: begin
                if (ppu_done) ns = S11_DMA_WRITEBACK;
            end
            S11_DMA_WRITEBACK: begin
                if (dma_wb_done_flag) ns = S12_UPDATE_M;
            end
            S12_UPDATE_M: begin
                if (m_cnt < M_tiles - 1) ns = S2_DMA_FETCH_A; // M 未完，推進空間映射
                else                     ns = S13_DONE;
            end
            S13_DONE: begin
                if (!asic_en_sync) ns = S0_IDLE;
            end
            default: ns = S0_IDLE;
        endcase
    end

    // =========================================================================
    // Datapath & Hardware Address Pointers
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst || cs == S0_IDLE) begin
            comp_A_len     <= 0; comp_B_len <= 0; comp_C_len <= 0;
            N_tiles        <= 1; K_tiles    <= 1; M_tiles    <= 1;
            packet_count   <= 1; operation_mode <= 0;
            GLB_A_base     <= 0; GLB_B_base <= 0; GLB_C_base <= 0;
            
            n_cnt <= 0; k_cnt <= 0; m_cnt <= 0;
            addr_acc_A <= 0; addr_acc_B <= 0; addr_acc_C <= 0;
        end else begin
            if (cs == S1_SHADOW_LATCH) begin
                comp_A_len     <= comp_A_len_in;
                comp_B_len     <= comp_B_len_in;
                comp_C_len     <= comp_C_len_in;
                
                // 解析 32-bit Command (防 0 處理)
                M_tiles        <= (cmd_m_val > 0) ? cmd_m_val : 1;
                K_tiles        <= (cmd_k_val > 0) ? cmd_k_val : 1;
                N_tiles        <= (cmd_n_val > 0) ? cmd_n_val : 1;
                packet_count   <= (cmd_pkt_val > 0) ? cmd_pkt_val : 16;
                operation_mode <= asic_cmd_in[`CMD_MODE_MSB : `CMD_MODE_LSB];
                
                GLB_A_base     <= GLB_A_base_addr;
                GLB_B_base     <= GLB_B_base_addr;
                GLB_C_base     <= GLB_C_base_addr;
            end 
            else if (cs == S7_UPDATE_N) begin
                // B 持續位移以滑動 Filter
                addr_acc_B <= addr_acc_B + comp_B_len;
                if (n_cnt < N_tiles - 1) begin
                    n_cnt <= n_cnt + 1;
                end else begin
                    n_cnt <= 0;
                end
            end 
            else if (cs == S8_UPDATE_K) begin
                // A 與 B 在 DRAM 都是連續存放 (Row-major: M*K 與 K*N)
                // K 推進時，A 自然向後取，B 自然向後取，皆不需要 Rewind
                addr_acc_A <= addr_acc_A + comp_A_len;
                if (k_cnt < K_tiles - 1) begin
                    k_cnt <= k_cnt + 1;
                end else begin
                    k_cnt <= 0;
                end
            end 
            else if (cs == S12_UPDATE_M) begin
                // M 推進 (IFMAP 換新的一區塊)。此時 B (Filter) 必須完整重複使用！
                addr_acc_B <= 32'd0;
                
                addr_acc_A <= addr_acc_A + comp_A_len; 
                addr_acc_C <= addr_acc_C + comp_C_len;
                m_cnt      <= m_cnt + 1;
            end
        end
    end

    // =========================================================================
    // Interface Logic
    // =========================================================================
    assign asic_done = (cs == S13_DONE);

    assign DMA_en =
        (cs == S2_DMA_FETCH_A    && !dma_a_done_flag)  ||
        (cs == S3_DMA_FETCH_B    && !dma_b_done_flag)  ||
        (cs == S11_DMA_WRITEBACK && !dma_wb_done_flag);

    assign DMA_mode =
        (cs == S2_DMA_FETCH_A)    ? `DMA_MODE_IFMAP  :
        (cs == S3_DMA_FETCH_B)    ? `DMA_MODE_FILTER :
        (cs == S11_DMA_WRITEBACK) ? `DMA_MODE_OFMAP  : 2'd0;

    assign DMA_DRAM_ADDR =
        (cs == S2_DMA_FETCH_A)    ? (A_fiber_base_addr  + addr_acc_A) :
        (cs == S3_DMA_FETCH_B)    ? (B_fiber_base_addr  + addr_acc_B) :
        (cs == S11_DMA_WRITEBACK) ? (C_tensor_base_addr + addr_acc_C) : 0;

    assign DMA_GLB_ADDR =
        (cs == S2_DMA_FETCH_A)    ? GLB_A_base :
        (cs == S3_DMA_FETCH_B)    ? GLB_B_base :
        (cs == S11_DMA_WRITEBACK) ? GLB_C_base : 0;

    assign DMA_len =
        (cs == S2_DMA_FETCH_A)    ? comp_A_len :
        (cs == S3_DMA_FETCH_B)    ? comp_B_len :
        (cs == S11_DMA_WRITEBACK) ? comp_C_len : 0;

    assign mc_start        = (cs == S5_MC_DISPATCH);
    assign mc_mode         = operation_mode;
    assign mc_glb_base_A   = GLB_A_base;
    assign mc_glb_base_B   = GLB_B_base;
    assign mc_packet_count = packet_count;

    assign global_mode  = operation_mode;
    assign global_flush = (cs == S9_FLUSH);

    // → pe_row_tail (B-3):k_cnt==0 的 K-tile 覆寫 buffer,否則累加;n_cnt*16 = 本 N-tile 基底欄
    assign pe_first_pass = (k_cnt == 0);
    assign pe_cur_n_base = 9'(n_cnt * `N_TILE_SIZE);

    assign PE_en =
        (cs >= S4_SEND_PE_CONFIG && cs <= S10_WAIT_PPU)
        ? {(`PE_ARRAY_H * `PE_ARRAY_W){1'b1}} : 0;

    assign PE_config = {operation_mode, e, p, q[1:0]}; 

    assign PEA_opsum_ready = (cs == S10_WAIT_PPU);
    assign opsum_tag_X     = 0;
    assign opsum_tag_Y     = 0;
    assign relu_sel        = operation_mode[0];
    assign Maxpool_en      = 1'b0;
    assign Maxpool_init    = 1'b0;

    assign set_XID            = 1'b0;
    assign set_YID            = 1'b0;
    assign set_LN             = 1'b0;
    assign ifmap_XID_scan_in  = 0;
    assign filter_XID_scan_in = 0;
    assign ipsum_XID_scan_in  = 0;
    assign opsum_XID_scan_in  = 0;
    assign ifmap_YID_scan_in  = 0;
    assign filter_YID_scan_in = 0;
    assign ipsum_YID_scan_in  = 0;
    assign opsum_YID_scan_in  = 0;
    assign LN_config_in       = 0;

    logic unused_ok;
    assign unused_ok = ^{r, t, PEA_opsum_valid};

endmodule
