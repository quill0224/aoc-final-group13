module SRAM_wrapper (
  input ACLK,
  input ARESETn,

  input [3:0]         AWID_S,
  input [31:0]        AWADDR_S,
  input [3:0]         AWLEN_S,
  input [2:0]         AWSIZE_S,//3'd2
  input [1:0]         AWBURST_S,//2'b01
  input               AWVALID_S,
  output logic        AWREADY_S,

  input [31:0]        WDATA_S,
  input [3:0]         WSTRB_S,
  input               WLAST_S,
  input               WVALID_S,
  output logic        WREADY_S,

  output logic [3:0]  BID_S,
  output logic [3:0]  BRESP_S,
  output logic        BVALID_S,
  input               BREADY_S,     

  input [3:0]         ARID_S,
  input [31:0]        ARADDR_S,
  input [3:0]         ARLEN_S,
  input [2:0]         ARSIZE_S,//3'd2
  input [1:0]         ARBURST_S,//2'b01
  input               ARVALID_S,
  output logic        ARREADY_S,    


  output logic [3:0]  RID_S,
  output logic [31:0] RDATA_S,
  output logic [1:0]  RRESP_S,
  output logic        RLAST_S,
  output logic        RVALID_S,
  input               RREADY_S



);

logic CEB, WEB;
logic [31:0] BWEB;
logic [31:0] ADDRESS;
logic [31:0] DI, DO;  
enum logic [3:0] {IDLE,AR_HS,AR_ADDR,R_DATA,R_HS,AW_HS,AW_ADDR,W_DATA,W_HS,B_RESPONSE  } state,next_state;
// parameter IDLE       = 4'd0;

// parameter AR_HS       = 4'd1;
// parameter AR_ADDR  = 4'd2;
// parameter R_DATA     = 4'd3;
// parameter R_HS     = 4'd4;

// parameter AW_HS       = 4'd5;
// parameter AW_ADDR  = 4'd6;
// parameter W_DATA     = 4'd7;
// parameter W_HS     = 4'd8;

// parameter B_RESPONSE = 4'd9;

// logic [3:0] state, next_state;

always_ff @( posedge ACLK or negedge ARESETn ) begin
    if(~ARESETn)

        state <= IDLE;
    else
        state <= next_state;
end

always_comb begin
    case (state)
        IDLE       : begin
            if (ARVALID_S) begin

                next_state = AR_HS;

            end else if (AWVALID_S) begin
                
                next_state = AW_HS;

            end else begin
                
                next_state = IDLE;
            end
        end
        AR_HS       : begin

            next_state = AR_ADDR;
        end
        AR_ADDR  : begin     

            next_state = R_DATA;

        end
        R_DATA     : begin  
		
            next_state = R_HS;
        end
        R_HS     : begin
            if (RREADY_S && RVALID_S) begin
			
				if(RLAST_S)begin
				
					next_state = IDLE;
				end else begin
				
					next_state = AR_ADDR;
				end
            end else begin
                
                next_state = R_HS;
            end
        end
        AW_HS       : begin
            if (AWREADY_S && AWVALID_S) begin

                next_state = AW_ADDR;

            end else begin
                
                next_state = AW_HS;
            end
        end
        AW_ADDR  : begin     

            next_state = W_DATA;

        end
        W_DATA     : begin               
                
            next_state = (WVALID_S)?W_HS:W_DATA;  
        end
        W_HS     : begin
            if ( WVALID_S && WREADY_S) begin

                next_state =(WLAST_S ) ? B_RESPONSE : AW_ADDR;

            end else begin
                
                next_state = W_HS;
            end
        end
        B_RESPONSE : begin
            if (BREADY_S && BVALID_S) begin

                next_state = IDLE;

            end else begin
                
                next_state = B_RESPONSE;
            end;
        end
        default: next_state = IDLE;
    endcase
end

logic [31:0] ADDRESS_LATCH;
logic [31:0] RDATA_S_LATCH;
logic [3:0] ARLEN_S_LATCH;
logic [3:0] ARID_S_LATCH;
logic [3:0] AWID_S_LATCH;
logic [3:0] read_data_count;
logic [3:0] write_data_count;

always_ff @( posedge ACLK or negedge ARESETn ) begin    //size跟burst要存嗎
	if (~ARESETn) begin
	
		ARLEN_S_LATCH <= 4'd0;
		ARID_S_LATCH <= 4'd0;
		AWID_S_LATCH <= 4'd0;

	end else if(ARVALID_S && ARREADY_S)begin
		
		ARLEN_S_LATCH <= ARLEN_S;
		ARID_S_LATCH <= ARID_S;

	end else if(AWVALID_S && AWREADY_S) begin

		AWID_S_LATCH <= AWID_S;
    
    end else begin
        
        AWID_S_LATCH <= AWID_S_LATCH;
    end
end

always_ff @( posedge ACLK or negedge ARESETn ) begin
    if (~ARESETn) begin
        
        ADDRESS_LATCH <= 32'd0;

    end else if (ARVALID_S && ARREADY_S) begin
        
        ADDRESS_LATCH <= ARADDR_S;

    end else if (AWVALID_S && AWREADY_S) begin
        
        ADDRESS_LATCH <= AWADDR_S;

    end else if (RVALID_S && RREADY_S) begin
        
        ADDRESS_LATCH <= ADDRESS_LATCH + 32'd4;

    end else if (WVALID_S && WREADY_S) begin
        
        ADDRESS_LATCH <= ADDRESS_LATCH + 32'd4;
    end
end

always_ff @( posedge ACLK or negedge ARESETn ) begin
    if(~ARESETn) begin
        
        RDATA_S_LATCH <= 32'd0;
    end else if (state == IDLE)begin
        
        RDATA_S_LATCH <= 32'd0;    
    end else if(state == R_DATA)begin

        RDATA_S_LATCH <= DO;
    end
end

////////////////計算有幾筆資料回傳////////////////
always_ff @( posedge ACLK or negedge ARESETn ) begin        
    if ((~ARESETn)) begin

        read_data_count   <= 4'd0;
		
	end else if (state == IDLE) begin 
	
		read_data_count   <= 4'd0;

    end else if ((RVALID_S) && (RREADY_S)) begin
        
        read_data_count   <= read_data_count + 4'd1;
    end 
end

always_ff @( posedge ACLK or negedge ARESETn ) begin        
    if ((~ARESETn)) begin

        write_data_count   <= 4'd0;
		
	end else if (state == IDLE) begin
		
		write_data_count   <= 4'd0;

    end else if ((WVALID_S) && (WREADY_S)) begin
        
        write_data_count   <= write_data_count + 4'd1;
    end 
end

assign ARREADY_S = (state == AR_HS) ? 1'b1 : 1'b0;

assign RID_S = 	(state == R_DATA)? ARID_S_LATCH : 4'd0;
assign RDATA_S = RDATA_S_LATCH;    
assign RRESP_S = 2'd0;    
assign RLAST_S = ((state == R_HS) && (read_data_count == ARLEN_S_LATCH)) ? 1'b1 : 1'b0;    
assign RVALID_S = (state == R_HS) ? 1'b1 : 1'b0;

assign AWREADY_S = (state == AW_HS) ? 1'b1 : 1'b0;
assign WREADY_S = (state == W_HS) ? 1'b1 : 1'b0;

assign BID_S = AWID_S_LATCH;		
assign BRESP_S = 4'd0;    
assign BVALID_S = (state == B_RESPONSE) ? 1'b1 : 1'b0; 


/////////////////SRAM/////////////////////
TS1N16ADFPCLLLVTA512X45M4SWSHOD i_SRAM(
    .SLP(1'b0),
    .DSLP(1'b0),
    .SD(1'b0),
    .PUDELAY(),
    .CLK(ACLK ), 
    .CEB(CEB  ), 
    .WEB(WEB  ),
    .A(ADDRESS[15:2]), 
    .D(DI     ),
    .BWEB(BWEB),
    .RTSEL(2'b01),
    .WTSEL(2'b01),
    .Q(DO     )
);

assign CEB = ((state == AR_ADDR) || (state == AW_ADDR) || (state == W_HS)) ? 1'b0 : 1'b1;
assign WEB = (state == AW_ADDR || state == W_HS) ? 1'b0 : 1'b1;
assign ADDRESS = ADDRESS_LATCH;
assign DI = WDATA_S;
assign BWEB = (state == W_HS)? 32'h00000000 : 32'hFFFFFFFF;
// assign BWEB =(state == W_HS)? {{8{~WSTRB_S[3]}},{8{~WSTRB_S[2]}},{8{~WSTRB_S[1]}},{8{~WSTRB_S[0]}}} : 32'hFFFFFFFF;
endmodule