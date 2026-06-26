module DMA_wrapper(
	input ACLK,
	input ARESETn,

    //write address (S)
	input [3:0]                 AWID_S,
	input [`AXI_ADDR_BITS-1:0] AWADDR_S,
	input [3:0]                AWLEN_S,
	input [`AXI_SIZE_BITS-1:0] AWSIZE_S,
    input [1:0]                AWBURST_S,
	input                      AWVALID_S,
	output                     AWREADY_S,

    //write data (S)
	input [`AXI_DATA_BITS-1:0] WDATA_S,
	input [`AXI_STRB_BITS-1:0] WSTRB_S,
	input                      WLAST_S,
	input                      WVALID_S,
	output                     WREADY_S,

    //write response (S)
	output logic [3:0]               BID_S,
	output       [1:0]               BRESP_S,
	output                           BVALID_S,
	input                            BREADY_S,

    //read address (M)
	output [`AXI_ID_BITS-1:0]   ARID_M,
	output [`AXI_ADDR_BITS-1:0] ARADDR_M,
	output [3:0]                ARLEN_M,
	output [`AXI_SIZE_BITS-1:0] ARSIZE_M,
	output [1:0]                ARBURST_M,
	output                      ARVALID_M,
	input                       ARREADY_M,

    //read data (M)
	input  [`AXI_ID_BITS-1:0]   RID_M,
	input  [`AXI_DATA_BITS-1:0] RDATA_M,
	input  [1:0]                RRESP_M,
	input                       RLAST_M,
	input                       RVALID_M,
	output                      RREADY_M,

    //write address (M)
    output [`AXI_ID_BITS-1:0]    AWID_M,
	output [`AXI_ADDR_BITS-1:0]  AWADDR_M,
	output [3:0]                 AWLEN_M,
	output [`AXI_SIZE_BITS-1:0]  AWSIZE_M,
	output [1:0]                 AWBURST_M,
	output                       AWVALID_M,
	input                        AWREADY_M,

    //write data (M)
    output [`AXI_DATA_BITS-1:0]  WDATA_M,
	output [`AXI_STRB_BITS-1:0]  WSTRB_M,                 
	output                       WLAST_M,       
	output                       WVALID_M, 
	input                        WREADY_M,

    //write response (M)
    input [`AXI_ID_BITS-1:0]    BID_M,
	input [1:0]                 BRESP_M, 
	input                       BVALID_M,
	output                      BREADY_M,

    //interrupt
    output logic                ext_interrupt
	
);

logic [13:0] Temp_addr;    //by word

//======= DMA Wire ========
logic WEB;
logic [13:0] A;
logic [31:0] DI;
logic [2:0] r_desc_choose;       //2'b00: DMAEN  2'b01: DMASRC   2'b10: DMADST  2'b11: DMALEN
logic busy_flag;
logic DMAEN_out;
logic [31:0] DMASRC_out;
logic [31:0] DMADST_out;
logic [31:0] DMALEN_out;

logic [31:0] w_data;

logic [31:0] AWADDR_S_LATCH;
logic [7:0]  AWID_S_LATCH;
logic r_ctrl_choose_w;
logic is_write_to_dmaen;
logic fetch_flag;
logic [3:0] awlen_latch;
logic [31:0] DESC_out;
logic DMA_interrupt;
logic [3:0] w_burst_counter;

//===========================

//=== handshake Signal =====
logic W_handshake_S;
logic AW_handshake_M,W_handshake_M,R_handshake_M,B_handshake_M;

assign W_handshake_S  = WVALID_S  && WREADY_S ;

assign AW_handshake_M = AWVALID_M && AWREADY_M;
assign W_handshake_M  = WVALID_M  && WREADY_M ;
assign R_handshake_M  = RVALID_M  && RREADY_M ;
assign B_handshake_M  = BVALID_M  && BREADY_M ; 
//===========================

///////////////////////////////////////////////////////////////////////
//========== FSM_C ============
parameter IDLE_C       = 3'd0;
parameter AW_HS_C       = 3'd1;
parameter AW_ADDR_C  = 3'd2;
parameter W_DATA_C     = 3'd3;
parameter W_HS_C      = 3'd4;
parameter B_RESPONSE_C = 3'd5;

logic [2:0] state_C, next_state_C;

always_ff @( posedge ACLK or negedge ARESETn ) begin
    if(!ARESETn)

        state_C <= 3'd0;
    else
        state_C <= next_state_C;
end

always_comb begin
    case (state_C)
        IDLE_C : begin
            if (AWVALID_S) begin

                next_state_C = AW_HS_C;

            end else begin
                
                next_state_C = IDLE_C;
            end
        end
        AW_HS_C : begin
            if (AWREADY_S && AWVALID_S) begin

                next_state_C = AW_ADDR_C;

            end else begin
                
                next_state_C = AW_HS_C;
            end
        end
        AW_ADDR_C  : begin     

            next_state_C = W_DATA_C;

        end
        W_DATA_C     : begin                  
            
            next_state_C = W_HS_C;
        end
        W_HS_C     : begin
            if (WLAST_S && WVALID_S && WREADY_S) begin

                next_state_C = B_RESPONSE_C;

            end else begin
                
                //next_state_C = W_DATA_C;
                 next_state_C = AW_ADDR_C;
            end
        end
        B_RESPONSE_C : begin
            if (BVALID_S && BREADY_S) begin

                next_state_C = IDLE_C;

            end else begin
                
                next_state_C = B_RESPONSE_C;
            end;
        end
        default:next_state_C = IDLE_C;
    endcase
end

always_ff @( posedge ACLK or negedge ARESETn ) begin    //size跟burst要存嗎
	if (~ARESETn) begin
	
		AWADDR_S_LATCH <= 32'd0;
        AWID_S_LATCH   <= 8'd0;

	end else if(AWVALID_S && AWREADY_S) begin

		AWADDR_S_LATCH <= AWADDR_S;
        AWID_S_LATCH   <= {4'd0,AWID_S};
    
    end else begin
        
        AWADDR_S_LATCH <= AWADDR_S_LATCH;
        AWID_S_LATCH   <= AWID_S_LATCH;
    end
end

logic desc_base_written;

always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin

        desc_base_written <= 1'b0;

    end else begin
        if ((state_C == W_HS_C) && WVALID_S && WREADY_S && (AWADDR_S_LATCH == 32'h10020200)) begin

            desc_base_written <= 1'b1;

        end else if ((state_C == W_HS_C) && WVALID_S && WREADY_S && (AWADDR_S_LATCH == 32'h10020100) && desc_base_written) begin

            desc_base_written <= 1'b0;

        end else begin

            desc_base_written <= desc_base_written;
        end
    end
end

// 在 WDATA 狀態時，根據閂鎖的位址判斷要寫入哪個暫存器
always_comb begin
    
    r_ctrl_choose_w   = 1'b0; 
    is_write_to_dmaen = 1'b0;

    // 只有在 FSM 處於寫入握手狀態 (W_HS_C) 時，才根據閂鎖的位址致能 r_ctrl_choose
    if ((state_C == W_HS_C) && WVALID_S && WREADY_S) begin
        if (AWADDR_S_LATCH == 32'h10020200) begin

            r_ctrl_choose_w   = 1'b0; // 0 = DESC_BASE
            
        end else if (AWADDR_S_LATCH == 32'h10020100 && desc_base_written) begin
            r_ctrl_choose_w   = 1'b1; // 1 = DMAEN
            is_write_to_dmaen = 1'b1;
        end
    end
end

/////////////////////////////////////////////////////////////////////////////////
//========== FSM_F ============
parameter IDLE_F       = 2'd0;
parameter AR_HS_F       = 2'd1;
parameter AR_ADDR_F  = 2'd2;
parameter R_DATA_F     = 2'd3;
//parameter R_HS     = 4'd4;

logic [1:0] state_F, next_state_F;

always_ff @( posedge ACLK or negedge ARESETn ) begin
    if(~ARESETn)

        state_F <= 2'd0;
    else
        state_F <= next_state_F;
end

always_comb begin
    case (state_F)
        IDLE_F       : begin
            if (fetch_flag) begin
                
                next_state_F = AR_HS_F;
            end else begin
                
                next_state_F = IDLE_F;
            end
        end
        AR_HS_F       : begin
            if (ARREADY_M && ARVALID_M) begin
                
                next_state_F = AR_ADDR_F;

            end else begin
                
                next_state_F = AR_HS_F;
            end
        end
        AR_ADDR_F  : begin     
            if (RVALID_M) begin
                
                next_state_F = R_DATA_F;

            end else begin
                next_state_F = AR_ADDR_F;
            end
        end
        R_DATA_F     : begin  
            if (RVALID_M && RREADY_M) begin
                
                next_state_F = (RLAST_M) ? IDLE_F : AR_ADDR_F;

            end else begin
                
                next_state_F = R_DATA_F;
            end
        end
    endcase
end

////////////////////////////////////////////////////////////////
logic [2:0] r_desc_counter;

always_ff @( posedge ACLK or negedge ARESETn ) begin
    if(!ARESETn) begin
        
        r_desc_counter <= 3'd0;

    end else begin
        // 當 FSM 處於 R_DATA 狀態且資料握手成功時，計數器 + 1
        if ((state_F == R_DATA_F) && RVALID_M && RREADY_M) begin
            if (RLAST_M) begin
                r_desc_counter <= 3'd0; // 完成後歸零
            end else begin
                r_desc_counter <= r_desc_counter + 3'd1;
            end
        end else if (state_F == IDLE_F) begin
            r_desc_counter <= 3'd0; // IDLE 時歸零
        end
    end
end

// 將計數器連接到 dma.sv 的輸入
assign r_desc_choose = r_desc_counter;

//========== FSM_E1 ============
parameter IDLE_E1       = 2'd0;
parameter AR_HS_E1       = 2'd1;
parameter AR_ADDR_E1  = 2'd2;
parameter R_DATA_E1     = 2'd3;
//parameter R_HS     = 4'd4;

logic [1:0] state_E1, next_state_E1;

always_ff @( posedge ACLK or negedge ARESETn ) begin
    if(~ARESETn)

        state_E1 <= 2'd0;
    else
        state_E1 <= next_state_E1;
end

logic [31:0] rd_cnt;
logic        rd_done;

always_comb begin
    case (state_E1)
        IDLE_E1       : begin
            if (busy_flag && !rd_done) begin
                
                next_state_E1 = AR_HS_E1;
            end else begin
                
                next_state_E1 = IDLE_E1;
            end
        end
        AR_HS_E1       : begin
            if (ARREADY_M && ARVALID_M) begin
                
                next_state_E1 = AR_ADDR_E1;

            end else begin
                
                next_state_E1 = AR_HS_E1;
            end
        end
        AR_ADDR_E1  : begin     
            if (RVALID_M) begin

                next_state_E1 = R_DATA_E1;

            end else begin
                
                next_state_E1 = AR_ADDR_E1;
            end

        end
        R_DATA_E1     : begin  
            if (RVALID_M && RREADY_M) begin

                next_state_E1 =(RLAST_M) ? IDLE_E1 : AR_ADDR_E1;

            end else begin
                
                next_state_E1 = R_DATA_E1;
            end
        end
    endcase
end



always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin

        rd_cnt  <= 32'd0;

    end else if (state_E1 == IDLE_E1 && !busy_flag) begin
        
        rd_cnt <= 32'd0;

    end else if ((RVALID_M && RREADY_M) && (state_E1 == R_DATA_E1)) begin

        rd_cnt <= rd_cnt + 32'd1;
    end
end

assign rd_done = ((rd_cnt == (DMALEN_out + 1)));  //  DMALEN_out + 1 

//========== FSM_E2 ============
parameter IDLE_E2       = 3'd0;
parameter AW_HS_E2       = 3'd1;
parameter AW_ADDR_E2  = 3'd2;
parameter W_DATA_E2     = 3'd3;
//parameter W_HS_E2      = 3'd4;
parameter B_RESPONSE_E2 = 3'd4;

logic [2:0] state_E2, next_state_E2;

always_ff @( posedge ACLK or negedge ARESETn ) begin
    if(~ARESETn)

        state_E2 <= 3'd0;
    else
        state_E2 <= next_state_E2;
end
logic empty_out;
logic [10:0] empty_out_cnt;
always @(posedge ACLK or negedge ARESETn) begin
    if (~ARESETn) begin
        empty_out_cnt <= 11'd0;
    end else begin
        empty_out_cnt <=(!empty_out && state_E2 == 3'd3)?empty_out_cnt + 11'd1:empty_out_cnt;
    end
end
always_comb begin
    case (state_E2)
        IDLE_E2 : begin
            if (busy_flag && !empty_out) begin

                next_state_E2 = AW_HS_E2;

            end else begin
                
                next_state_E2 = IDLE_E2;
            end
        end
        AW_HS_E2 : begin
            if (AWREADY_M && AWVALID_M ) begin

                next_state_E2 = AW_ADDR_E2;

            end else begin
                
                next_state_E2 = AW_HS_E2;
            end
        end
        AW_ADDR_E2  : begin     

            next_state_E2 = W_DATA_E2;

        end
        W_DATA_E2     : begin                  
            if (WREADY_M && WVALID_M) begin
			
				if(WLAST_M)begin
				
					next_state_E2 = B_RESPONSE_E2;
				end else begin
				
					next_state_E2 = W_DATA_E2;
				end
            end else begin
                
                next_state_E2 = W_DATA_E2;
            end
        end
        B_RESPONSE_E2 : begin
            if (BVALID_M && BREADY_M) begin

                next_state_E2 = IDLE_E2;

            end else begin
                
                next_state_E2 = B_RESPONSE_E2;
            end;
        end
        default: next_state_E2 = IDLE_E2;
    endcase
end

always_ff @( posedge ACLK or negedge ARESETn ) begin
    if (!ARESETn)

        w_burst_counter <= 4'd0;

    else if (WVALID_M && WREADY_M) begin

        w_burst_counter <= w_burst_counter + 4'd1;

    end else if (state_E2 == IDLE_E2) 

        w_burst_counter <= 4'd0;
end

always_ff @( posedge ACLK or negedge ARESETn ) begin
	if (~ARESETn) begin
	
        awlen_latch <= 4'd0;

	end else if(AWVALID_M && AWREADY_M) begin

        awlen_latch <= DMALEN_out[3:0];
    
    end else begin
        
        awlen_latch <= awlen_latch;
    end
end

assign WEB          = ((state_C == W_HS_C) && WVALID_S && WREADY_S) ? 1'b0 : 1'b1;
assign fetch_finish = ((state_F == R_DATA_F) && RVALID_M && RREADY_M && RLAST_M) ? 1'd1 : 1'd0;

//////////////////////////////////////////////////////////////
//write address (S)
assign AWREADY_S = (state_C == AW_HS_C) ? 1'b1 : 1'b0;

//write data (S)
assign WREADY_S  = (state_C == W_HS_C) ? 1'b1 : 1'b0;

//write response (S)
assign BVALID_S  = (state_C == B_RESPONSE_C) ? 1'b1 : 1'b0;
assign BRESP_S   = 2'd0;
assign BID_S     = AWID_S_LATCH[3:0];

///////////////////////////////////////////////////////////////
//read address (M)
assign ARID_M    = 4'd0;
assign ARADDR_M  = (state_F != IDLE_F) ? DESC_out : // FSM_F (Fetch) 優先
                   (state_E1 != IDLE_E1) ? DMASRC_out : // FSM_E1 (Execute)
                   32'd0;

assign ARLEN_M   = (state_F != IDLE_F) ? 4'd4 : // 讀取 5 (4+1) 筆資料
                   (state_E1 != IDLE_E1) ? DMALEN_out[3:0] : // << 修正 Typo: [3:0]
                   4'd0;

assign ARSIZE_M  = 3'd2; // 4 bytes
assign ARBURST_M = 2'b01; // INCR
assign ARVALID_M = (state_E1 == AR_HS_E1) || (state_F == AR_HS_F) ? 1'b1 : 1'b0;

//read data (M)
assign RREADY_M  = (state_E1 == R_DATA_E1) || (state_F == R_DATA_F) ? 1'b1 : 1'b0;

//////////////////////////////////////////////////////////////
//write address (M)
assign AWID_M    = 4'd0;
assign AWADDR_M  = (busy_flag) ? DMADST_out : 32'd0;
assign AWLEN_M   = DMALEN_out[3:0];
assign AWSIZE_M  = 3'd2; // 4 bytes
assign AWBURST_M = 2'b01; // INCR
assign AWVALID_M = (state_E2 == AW_HS_E2 ) ? 1'b1 : 1'b0;

//write data (M)
assign WDATA_M   = w_data;
assign WSTRB_M   = (WVALID_M)? 4'b0000 : 4'b1111;
assign WLAST_M   = ((state_E2 == W_DATA_E2) && (w_burst_counter == awlen_latch));
assign WVALID_M  = ((state_E2 == W_DATA_E2) && !empty_out) ? 1'b1 : 1'b0;

//write response (M)
assign BREADY_M  = (state_E2 == B_RESPONSE_E2) ? 1'b1 : 1'b0;

//////////////////////////////////////////////////////////////
//interrupt
assign ext_interrupt = DMA_interrupt;

//assign RDATA_M_reg = () ? :;

DMA dma(
    .clk(ACLK),
    .rst(!ARESETn),
    .DMAEN(1'b0),    
    .DESC_BASE(32'd0),
    .S3_W_HS(W_handshake_S),
    .M2_R_HS(R_handshake_M),
    .M2_W_HS(W_handshake_M),    
    .WEB(WEB),
    .r_ctrl(WDATA_S),
    .r_ctrl_choose(r_ctrl_choose_w),
    .r_desc(RDATA_M),
    .r_desc_choose(r_desc_choose),
    .r_data(RDATA_M),
    .fetch_finish(fetch_finish),    
    .B_HS(B_handshake_M),          
    .w_data(w_data),
    .fetch_flag(fetch_flag),     
    
    .busy_flag(busy_flag), 
    .done_flag(done_flag),      
    .empty_out(empty_out), 
    .DMASRC_out(DMASRC_out),
    .DMADST_out(DMADST_out),
    .DMALEN_out(DMALEN_out),
    .DESC_out(DESC_out),
    .DMA_interrupt(DMA_interrupt)
);
endmodule