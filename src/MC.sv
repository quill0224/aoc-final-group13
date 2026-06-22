`include "AXI/AXI_define.svh"
`include "ASIC.svh"

// =============================================================================
// MC.sv — Matrix Controller
// 負責解析 160-bit Sparse Packet (INT8 量化格式)
// Word 0: {Length[15:0], Bitmask[15:0]}
// Word 1~4: NZ Payloads (每 4 個 INT8 封裝為 1 個 32-bit Word)
// 備註：GLB 為 Byte-Addressing，Word 位址偏移需乘 4 (左移 2)
// =============================================================================

module MC #(
    parameter GLB_ADDR_BITS = 16,
    parameter PKT_CNT_BITS  = 16
)(
    input  logic                         clk,
    input  logic                         rst,

    input  logic                         mc_start,        
    input  logic [1:0]                   mc_mode,         
    input  logic [GLB_ADDR_BITS-1:0]     mc_glb_base_A,   
    input  logic [GLB_ADDR_BITS-1:0]     mc_glb_base_B,   
    input  logic [PKT_CNT_BITS-1:0]      mc_packet_count, 
    output logic                         k_done,          

    output logic                         mc_glb_ren_A,    
    output logic [GLB_ADDR_BITS-1:0]     mc_glb_addr_A,   
    input  logic [31:0]                  glb_rdata_A,     
    
    output logic                         mc_glb_ren_B,    
    output logic [GLB_ADDR_BITS-1:0]     mc_glb_addr_B,   

    output logic                         pe_cfg_valid,
    input  logic                         pe_cfg_ready,
    output logic [15:0]                  pe_cfg_length,
    output logic [15:0]                  pe_cfg_bitmask,

    output logic                         pe_data_valid,
    input  logic                         pe_data_ready,
    output logic [31:0]                  pe_data_nzvalue
);

    typedef enum logic [2:0] {
        ST_IDLE      = 3'd0,
        ST_REQ_HDR   = 3'd1, 
        ST_WAIT_HDR  = 3'd2, 
        ST_SEND_CFG  = 3'd3, 
        ST_REQ_DATA  = 3'd4, 
        ST_WAIT_DATA = 3'd5, 
        ST_NEXT_PKT  = 3'd6, 
        ST_DONE      = 3'd7  
    } mc_state_t;

    mc_state_t cs, ns;

    logic [GLB_ADDR_BITS-1:0] pkt_base_addr; 
    logic [PKT_CNT_BITS-1:0]  pkt_cnt;       
    logic [2:0]               word_cnt;      
    logic [PKT_CNT_BITS-1:0]  reg_pkt_max;

    logic [15:0]              reg_length;
    logic [15:0]              reg_bitmask;

    // [Iris 新增] A/B 兩段 phase 旗標:0=A 段、1=B 段
    logic                     cur_is_b;
    // [Iris 新增] reg_length[15] 帶 A/B tag,實際封包長度只取低 5 bit
    wire  [4:0]               eff_length = reg_length[4:0];

    // 將 INT8 數量轉換為 32-bit Word 請求數量 (0~4)
    logic [2:0]               target_words;
    always_comb begin
        // [Iris 修改] 改用 eff_length(遮掉 reg_length[15] 的 A/B tag)
        if (eff_length == 5'd0)        target_words = 3'd0;
        else if (eff_length <= 5'd4)   target_words = 3'd1;
        else if (eff_length <= 5'd8)   target_words = 3'd2;
        else if (eff_length <= 5'd12)  target_words = 3'd3;
        else                           target_words = 3'd4;
    end

    always_ff @(posedge clk) begin
        if (rst) cs <= ST_IDLE;
        else     cs <= ns;
    end

    always_comb begin
        ns = cs;
        case (cs)
            ST_IDLE:      if (mc_start) ns = ST_REQ_HDR;
            ST_REQ_HDR:   ns = ST_WAIT_HDR; 
            ST_WAIT_HDR:  ns = ST_SEND_CFG; 
            ST_SEND_CFG:  begin
                if (pe_cfg_ready) begin
                    // [Iris 修改] 用 eff_length 判斷空封包(避開 tag bit)
                    if (eff_length == 5'd0) ns = ST_NEXT_PKT;
                    else                    ns = ST_REQ_DATA;
                end
            end
            ST_REQ_DATA:  ns = ST_WAIT_DATA; 
            ST_WAIT_DATA: begin
                if (pe_data_ready) begin
                    if (word_cnt == target_words) ns = ST_NEXT_PKT;
                    else                          ns = ST_REQ_DATA; 
                end
            end
            ST_NEXT_PKT:  begin
                // [Iris 修改] 只有「B 段最後一包」才 DONE;其餘(A 段完成 or 未送完)都回 ST_REQ_HDR
                if (pkt_cnt == reg_pkt_max - 1 && cur_is_b) ns = ST_DONE;
                else                                        ns = ST_REQ_HDR;
            end
            ST_DONE:      ns = ST_IDLE;
            default:      ns = ST_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            pkt_base_addr <= '0;
            pkt_cnt       <= '0;
            word_cnt      <= '0;
            reg_pkt_max   <= '0;
            reg_length    <= '0;
            reg_bitmask   <= '0;
            cur_is_b      <= 1'b0;  // [Iris 新增]
        end else begin
            case (cs)
                ST_IDLE: begin
                    pkt_cnt  <= '0;
                    cur_is_b <= 1'b0;   // [Iris 新增] 每次重新從 A 段開始
                    if (mc_start) begin
                        pkt_base_addr <= mc_glb_base_A;
                        reg_pkt_max   <= mc_packet_count;
                    end
                end
                ST_WAIT_HDR: begin
                    // 鎖存標頭：高位元為長度，低位元為遮罩
                    reg_length  <= glb_rdata_A[31:16];
                    reg_bitmask <= glb_rdata_A[15:0];
                end
                ST_SEND_CFG: begin
                    if (pe_cfg_ready) word_cnt <= 3'd1; 
                end
                ST_WAIT_DATA: begin
                    // 取消 reg_nzvalue 鎖存，由 assign 直接 Bypass GLB 讀出值，消除 1-cycle 延遲
                    if (pe_data_ready) word_cnt <= word_cnt + 1;
                end
                ST_NEXT_PKT: begin
                    // [Iris 修改] A 段最後一包 → 切 B 段:base 改指 GLB_B、pkt_cnt 歸零
                    if (pkt_cnt == reg_pkt_max - 1 && !cur_is_b) begin
                        cur_is_b      <= 1'b1;
                        pkt_cnt       <= '0;
                        pkt_base_addr <= mc_glb_base_B;
                    end else begin
                        pkt_cnt       <= pkt_cnt + 1;
                        // 【Byte-Addressing 對齊修正】: 160-bit 封包 = 20 Bytes，每次跳轉固定 +20
                        pkt_base_addr <= pkt_base_addr + 16'd20;
                    end
                end
                default: ;
            endcase
        end
    end

    // 輸出介面邏輯
    assign mc_glb_ren_A  = (cs == ST_REQ_HDR) || (cs == ST_REQ_DATA);
    assign mc_glb_ren_B  = 1'b0; 
    
    // 【Byte-Addressing 偏移修正】: word_cnt * 4 (左移 2 位元)
    assign mc_glb_addr_A = (cs == ST_REQ_HDR) ? pkt_base_addr : (pkt_base_addr + {11'd0, word_cnt, 2'b00});
    assign mc_glb_addr_B = '0;

    assign pe_cfg_valid   = (cs == ST_SEND_CFG);
    assign pe_cfg_length  = reg_length;
    assign pe_cfg_bitmask = reg_bitmask;

    // 【Bypass 修正】: 處於 ST_WAIT_DATA 時直接導通 SRAM 讀出資料
    assign pe_data_valid   = (cs == ST_WAIT_DATA);
    assign pe_data_nzvalue = glb_rdata_A;

    assign k_done = (cs == ST_DONE);

    logic unused_ok;
    // [Iris 修改] mc_glb_base_B 已被 B 段使用,從 unused sink 移除
    assign unused_ok = &{1'b0, mc_mode, 1'b0};

endmodule
