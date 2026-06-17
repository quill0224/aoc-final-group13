module DRAM_FSM(

	input ACLK,
	input ARESETn,
	
	//WRITE ADDRESS
	input [`AXI_IDS_BITS-1:0] AWID,
	input [`AXI_ADDR_BITS-1:0] AWADDR,
	input [3:0] AWLEN,
	input [`AXI_SIZE_BITS-1:0] AWSIZE,
	input [1:0] AWBURST,
	input AWVALID,
	output logic AWREADY,
	//WRITE DATA
	input [`AXI_DATA_BITS-1:0] WDATA,
	input [`AXI_STRB_BITS-1:0] WSTRB,
	input WLAST,
	input WVALID,
	output logic WREADY,
	//WRITE RESPONSE
	output logic [`AXI_IDS_BITS-1:0] BID,
	output logic [1:0] BRESP,
	output logic BVALID,
	input BREADY,
	//READ ADDRESS
	input [`AXI_IDS_BITS-1:0] ARID,
	input [`AXI_ADDR_BITS-1:0] ARADDR,
	input [3:0] ARLEN,
	input [`AXI_SIZE_BITS-1:0] ARSIZE,
	input [1:0] ARBURST,
	input ARVALID,
	output logic ARREADY,
	//READ DATA
	output logic [`AXI_IDS_BITS-1:0] RID,
	output logic [`AXI_DATA_BITS-1:0] RDATA,
	output logic [1:0] RRESP,
	output logic RLAST,
	output logic RVALID,
	input RREADY,
	//DRAM
	output logic CSn,
	output logic [3:0]WEn,
	output logic RASn,
	output logic CASn,
	output logic [10:0]A,
	output logic [31:0]D,
	input [31:0]Q,
	input VALID
);
	//////////////reg//////////////
	//logic [10:0] row_reg;
	//logic [9:0] column_reg;
	logic [`AXI_ADDR_BITS-1:0] ADDR_reg;
	logic [`AXI_IDS_BITS-1:0] ARID_reg,AWID_reg;
	logic [`AXI_LEN_BITS-1:0] ARLEN_reg,AWLEN_reg,ARLEN_counter;
	logic [`AXI_DATA_BITS-1:0] WDATA_reg,RDATA_reg;
	logic [`AXI_STRB_BITS-1:0] WSTRB_reg;
	logic RVALID_reg;
	logic [1:0]ARBURST_reg,AWBURST_reg;
	logic [2:0]DRAM_counter;
	logic [10:0]current_row,activate_row;
	logic [9:0]current_column;
	//////////////state//////////////
	// parameter IDLE = 4'd0,ReadAddress = 4'd1,ReadIDLE = 4'd2,ReadData= 4'd3,WriteAddress = 4'd4,WriteIDLE = 4'd5,WriteData_HS = 4'd6,WriteData = 4'd7,WriteResponse = 4'd8,PRE = 4'd9,ACT = 4'd10;
	enum logic [3:0] { IDLE = 4'd0,ReadAddress = 4'd1,ReadIDLE = 4'd2,ReadData= 4'd3,WriteAddress = 4'd4,WriteIDLE = 4'd5,WriteData_HS = 4'd6,WriteData = 4'd7,WriteResponse = 4'd8,PRE = 4'd9,ACT = 4'd10 } next_state,state;
	// logic [3:0]next_state,state;
	
	always_ff @(posedge ACLK or posedge ARESETn)begin
        if (ARESETn)begin
            state <= IDLE;	
		end
        else begin
            state <= next_state;
		end
    end
	//////////AR_reg//////////
	always_ff @(posedge ACLK or posedge ARESETn)begin
		if (ARESETn)begin
			ARID_reg <= 8'd0;		
			ARLEN_reg <= 8'd0;	
			ARBURST_reg <= 2'd0;	
		end
        else begin
			if (ARREADY && ARVALID)begin
				ARID_reg <= ARID;
				ARBURST_reg <= ARBURST;
				ARLEN_reg <= {4'd0,ARLEN};
			end
			else begin
				ARID_reg <= ARID_reg;
				ARBURST_reg <= ARBURST_reg;
				ARLEN_reg <= ARLEN_reg;
			end
		end
	end
	//////////R_reg//////////
	always_ff @(posedge ACLK or posedge ARESETn) begin
		if (ARESETn)begin
			RDATA_reg <= 32'b0;	
		end		
        else begin
			if(VALID && current_row == activate_row)begin
				RDATA_reg <= Q;
			end
			else begin
				RDATA_reg <= RDATA_reg;
			end
		end
	end

	//////////R_reg//////////
	always_ff @(posedge ACLK or posedge ARESETn) begin
		if (ARESETn)begin
			RVALID_reg <= 1'b0;
		end
		else begin
			if(VALID)begin
				RVALID_reg <= 1'b1;
			end
			else if(RVALID && RREADY)begin
				RVALID_reg <= 1'b0;
			end
			else begin
				RVALID_reg <= 1'b0;
			end
		end
	end
	//////////AW_reg//////////
	always_ff @(posedge ACLK or posedge ARESETn) begin
		if (ARESETn)begin
			AWID_reg <= 8'd0;
			AWLEN_reg <= 8'd0;	
			AWBURST_reg <= 2'd0;
		end
        else begin
			if (AWREADY && AWVALID)begin
				AWID_reg <= AWID;
				AWBURST_reg <= AWBURST;
				AWLEN_reg <= {4'd0,AWLEN};
			end
			else begin
				AWID_reg <= AWID_reg;
				AWBURST_reg <= AWBURST_reg;
				AWLEN_reg <= AWLEN_reg;
			end
		end
	end
	//////////W_reg//////////
	always_ff @(posedge ACLK or posedge ARESETn) begin
		if (ARESETn)begin
			WDATA_reg <= 32'b0;	
			WSTRB_reg <= 4'd0;			
		end
        else begin
			if(WREADY && WVALID)begin
				WDATA_reg <= WDATA;
				WSTRB_reg <= WSTRB;
			end
			else begin
				WDATA_reg <= WDATA_reg;
				WSTRB_reg <= WSTRB_reg;
			end
		end
	end
	/////////Address_reg/////////
	always_ff @(posedge ACLK or posedge ARESETn) begin
		if (ARESETn)
			ADDR_reg <= 32'b0;		
		else if(ARREADY && ARVALID)
			ADDR_reg <= ARADDR;
		else if(AWREADY && AWVALID)
			ADDR_reg <= AWADDR;
		else if((ARLEN_counter != ARLEN_reg) && RREADY && RVALID)
			ADDR_reg <= ADDR_reg + 32'd4;
		else 
			ADDR_reg <= ADDR_reg;
	end
	/////////counter_reg/////////
	always_ff @(posedge ACLK or posedge ARESETn) begin
		if (ARESETn)begin
			ARLEN_counter <= 8'd0;
			DRAM_counter <= 3'd0;
		end
		else begin
			////////計算Read是否到最後一個address////////
			if(state == IDLE)
				ARLEN_counter <= 8'd0;
			else if(RREADY && RVALID)
				ARLEN_counter <= ARLEN_counter + 8'd1;
			else 
				ARLEN_counter <= ARLEN_counter;
			///////DRAM延遲///////
			if(state != next_state)
				DRAM_counter <= 3'd0;
			else if(DRAM_counter == 3'd4)
				DRAM_counter <= DRAM_counter;
			else 
				DRAM_counter <= DRAM_counter + 3'd1;
			
		end
	end
	/////////row_reg、column_reg/////////
	always_ff @(posedge ACLK or posedge ARESETn) begin
		if (ARESETn)begin
			activate_row <= 11'd0;
			current_row <= 11'd0;
			current_column <= 10'd0;
		end
		else begin
			if(state == ACT)
				activate_row <= ADDR_reg[22:12];
			else
				activate_row <= activate_row;
			
			current_row <= ADDR_reg[22:12];
			current_column <= ADDR_reg[11:2];
		end
	end
	
	always_comb begin
		case (state)
			IDLE: begin	
                if(ARVALID)
					next_state = ReadAddress;
				else if(AWVALID)
					next_state = WriteAddress;
				else
					next_state = IDLE;
            end
			ReadAddress:begin
				if(ARREADY && ARVALID)
					next_state = ReadIDLE;
				else
					next_state = ReadAddress;
			end
			ReadIDLE:begin
				if(RVALID && RREADY && ARLEN_reg == ARLEN_counter)
					next_state = IDLE;
				else if(DRAM_counter < 3'd2)
					next_state = ReadIDLE;
				else if(ADDR_reg[22:12] != activate_row)
					next_state = PRE;
				else
					next_state = ReadData;
			end
			ReadData:begin
				if(DRAM_counter < 3'd4)
					next_state = ReadData;
				else
					next_state = ReadIDLE;
			end
			WriteAddress:begin
				if(AWVALID && AWREADY)
					next_state = WriteIDLE;
				else
					next_state = WriteAddress;
			end
			WriteIDLE:begin
				if(ADDR_reg[22:12] != activate_row)
					next_state = PRE;
				else
					next_state = WriteData_HS;
			end
			WriteData_HS:begin
				if(WREADY && WVALID)
					next_state = WriteData;
				else
					next_state = WriteData_HS;
			end
			WriteData:begin
				if(DRAM_counter < 3'd4)
					next_state = WriteData;
				else
					next_state = WriteResponse;
			end
			WriteResponse:begin
				if(BREADY && BVALID)
					next_state = IDLE;
				else
					next_state = WriteResponse;
			end
			PRE:begin
				if(DRAM_counter < 3'd4)
					next_state = PRE;
				else
					next_state = ACT;
			end
			ACT:begin
				if(DRAM_counter < 3'd4)
					next_state = ACT;
				else if(WVALID)
					next_state = WriteIDLE;
				else
					next_state = ReadIDLE;
			end
			default:next_state = IDLE;
		endcase
	end
	
	
	////////////AXI控制////////////
	assign ARREADY = (state == ReadAddress) ? 1'b1 : 1'b0;
	assign AWREADY = (state == WriteAddress) ? 1'b1 : 1'b0;
	assign RVALID = (VALID && state == ReadIDLE )? 1'b1 : 1'b0;	
	assign RID = (state == ReadData) ? ARID_reg : 8'd0;
	assign RDATA = (state == ReadIDLE && VALID) ? Q : RDATA_reg;
	assign RRESP = 2'b00;
	assign RLAST = (RVALID && (ARLEN_counter == ARLEN_reg))? 1'b1 : 1'b0;
	assign WREADY = (state == WriteData_HS) ? 1'b1 : 1'b0;
	assign BRESP = 2'b00;
	assign BID = (state == WriteResponse) ? AWID_reg : 8'd0;
	assign BVALID = (state == WriteResponse)? 1'b1 : 1'b0;
	////////////DRAM控制////////////
	assign CSn = (state == IDLE)? 1'b1 : 1'b0;
	always_comb begin
		if(state == PRE && DRAM_counter == 3'd0)
			WEn = 4'h0;
		else if(state == WriteData && DRAM_counter == 3'd0)
			WEn = WSTRB_reg;
		else
			WEn = 4'hf;
	end
	assign RASn = ((state == ACT || state == PRE) && DRAM_counter == 3'd0)? 1'b0 : 1'b1;
	assign CASn = ((state == WriteData || state == ReadData) && DRAM_counter == 3'd0)? 1'b0 : 1'b1;
	assign A = (state == WriteData || state == ReadData)? {1'b0,ADDR_reg[11:2]} : (state == PRE)? activate_row : ADDR_reg[22:12];
	assign D = WDATA_reg;
	
endmodule