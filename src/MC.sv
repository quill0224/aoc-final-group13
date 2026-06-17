`include "AXI/AXI_define.svh"
`include "ASIC.svh"

// =============================================================================
// MC.sv — Matrix Controller for PE Array Data Feeding
// (Fixed: Counter-Driven FSM for precise Data/Latency alignment)
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
    output logic                         mc_glb_ren_B,    
    output logic [GLB_ADDR_BITS-1:0]     mc_glb_addr_B,   

    output logic                         pe_data_valid    
);

    typedef enum logic [1:0] {
        MC_IDLE  = 2'b00,
        MC_RUN   = 2'b01,
        MC_DONE  = 2'b10
    } mc_state_t;

    mc_state_t cs, ns;

    logic [GLB_ADDR_BITS-1:0] reg_base_A;
    logic [GLB_ADDR_BITS-1:0] reg_base_B;
    logic [PKT_CNT_BITS-1:0]  reg_pkt_max;
    logic [1:0]               reg_mode;

    logic [PKT_CNT_BITS-1:0]  pkt_cnt;       
    logic                     vld_pipe_reg;  
    logic                     mc_ren_active; 

    // =========================================================================
    // FSM
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) cs <= MC_IDLE;
        else     cs <= ns;
    end

    always_comb begin
        ns = cs;
        case (cs)
            MC_IDLE: if (mc_start) ns = MC_RUN;
            MC_RUN:  begin
                // 當前週期如果已經送出了最後一個 index 的讀取請求，
                // 下一拍就該進入 DONE 狀態發送 k_done 脈衝。
                if (pkt_cnt == reg_pkt_max - 1) begin
                    ns = MC_DONE;
                end
            end
            MC_DONE: ns = MC_IDLE;
            default: ns = MC_IDLE;
        endcase
    end

    // =========================================================================
    // Datapath & Control Registers
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            reg_base_A   <= {GLB_ADDR_BITS{1'b0}};
            reg_base_B   <= {GLB_ADDR_BITS{1'b0}};
            reg_pkt_max  <= {PKT_CNT_BITS{1'b0}};
            reg_mode     <= 2'b00;
            pkt_cnt      <= {PKT_CNT_BITS{1'b0}};
            vld_pipe_reg <= 1'b0;
        end else begin
            case (cs)
                MC_IDLE: begin
                    pkt_cnt      <= {PKT_CNT_BITS{1'b0}};
                    vld_pipe_reg <= 1'b0;
                    if (mc_start) begin
                        reg_base_A  <= mc_glb_base_A;
                        reg_base_B  <= mc_glb_base_B;
                        reg_pkt_max <= mc_packet_count;
                        reg_mode    <= mc_mode;
                    end
                end
                
                MC_RUN: begin
                    // 在 RUN 狀態下，必定發起讀取，因此下一拍的 Valid 一定為 1
                    vld_pipe_reg <= 1'b1; 
                    
                    // 只有在還沒達到最後一個 index 時才遞增計數器，
                    // 避免計數器超車造成位址跑過頭。
                    if (pkt_cnt < reg_pkt_max - 1) begin
                        pkt_cnt <= pkt_cnt + 1;
                    end
                end
                
                MC_DONE: begin
                    // 進入 DONE 的當下，是最後一筆資料從 SRAM 吐出的時間，
                    // pe_data_valid (vld_pipe_reg) 必須依然維持 1，
                    // 且我們不立刻將 vld_pipe_reg 清 0，而是等跳轉回 IDLE 處理。
                    pkt_cnt      <= {PKT_CNT_BITS{1'b0}};
                    vld_pipe_reg <= 1'b0; 
                end
                
                default: ;
            endcase
        end
    end

    // =========================================================================
    // Output Assignments
    // =========================================================================
    
    // 【k_done】 在 DONE 狀態時發出 1 拍的脈衝
    assign k_done = (cs == MC_DONE);

    // 【讀取致能】 只在 RUN 狀態下發起 SRAM 讀取請求
    assign mc_ren_active = (cs == MC_RUN);
    assign mc_glb_ren_A  = mc_ren_active;
    assign mc_glb_ren_B  = mc_ren_active;

    // 【位址產生】 因為 pkt_cnt 現在不會超車，直接利用當前的 pkt_cnt 產生即可。
    // 在 MC_RUN 的第 0 拍，pkt_cnt=0 -> addr = Base + 0
    // 在 MC_RUN 的第 1 拍，pkt_cnt=1 -> addr = Base + 4
    assign mc_glb_addr_A = reg_base_A + (pkt_cnt << 2);
    assign mc_glb_addr_B = reg_base_B + (pkt_cnt << 2);

    // 【資料有效】 負責延遲一拍通知 PE Array
    assign pe_data_valid = vld_pipe_reg;

    logic unused_ok;
    assign unused_ok = &{1'b0, reg_mode, 1'b0};

endmodule