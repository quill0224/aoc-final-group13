
    module CPU_wrapper(
    input ACLK,		 
    input rst,
    input interrupt,WTO,		 
    output    [3:0]   AWID_M1,	 
    output    [31:0]  AWADDR_M1,		 
    output    [3:0]   AWLEN_M1,		
    output    [2:0]   AWSIZE_M1,		
    output    [1:0]   AWBURST_M1,		
    output            AWVALID_M1,		 
    input             AWREADY_M1,

    output    [31:0]  WDATA_M1,       
    output    [3:0]   WSTRB_M1,		               
    output            WLAST_M1,         
    output            WVALID_M1,     
    input             WREADY_M1,	

    input     [3:0]   BID_M1,		  	
    input     [1:0]   BRESP_M1,		 
    input             BVALID_M1,      
    output            BREADY_M1, 

    output    [3:0]   ARID_M1,		 
    output    [31:0]  ARADDR_M1,       
    output    [3:0]   ARLEN_M1,        
    output    [2:0]   ARSIZE_M1,       
    output    [1:0]   ARBURST_M1,      
    output            ARVALID_M1,		 
    input             ARREADY_M1,  

    input     [3:0]   RID_M1,         
    input     [31:0]  RDATA_M1,        
    input     [1:0]   RRESP_M1,       
    input             RLAST_M1,       
    input             RVALID_M1,      
    output            RREADY_M1,   

    output    [3:0]   ARID_M0,		 
    output    [31:0]  ARADDR_M0,       
    output    [3:0]   ARLEN_M0,        
    output    [2:0]   ARSIZE_M0,       
    output    [1:0]   ARBURST_M0,      
    output            ARVALID_M0,		 
    input             ARREADY_M0, 

    input     [3:0]   RID_M0,         
    input     [31:0]  RDATA_M0,        
    input     [1:0]   RRESP_M0,       
    input             RLAST_M0,       
    input             RVALID_M0,      
    output            RREADY_M0

);


enum logic [3:0] {
            IDLE_DM,
            AR_VALID_DM,
            R_WAIT_DM,
            R_READY_DM,
            AW_VALID_DM,
            AW_DONE_DM,
            W_VALID_DM,
            B_WAIT_DM,
            B_READY_DM
}state_DM,next_state_DM;

enum logic [3:0] {
            IDLE_IM,
            AR_VALID_IM,
            R_WAIT_IM,
            R_READY_IM
}state_IM,next_state_IM;

logic [1:0] DM_inst_reg,DM_inst,DM_inst_type;//10是讀(L)11是寫(S)
logic [3:0] W_DATA_count,wstrb,wstrb_DM;
logic [31:0] IM_do,DM_do,DM_do_data;//
logic stop_IM,stop_DM;
logic [31:0] PC_for_IM,araddr_IM;
logic [31:0] wdata_DM,awaddr_DM,araddr_DM;
logic [31:0] rs2_out_reg3,alu_out_reg3;
logic jb_save;

//cache
logic [127:0] IM_cache_data_pack,DM_cache_data_pack;
logic [1:0]   IM_cache_cnt,DM_cache_cnt;
logic stop_IM_with_cache,stop_DM_with_cache;
//IM_cache to CPU
logic [31:0] I_cache_core_out,D_cache_core_out;
//IM_cache to wrapper
logic I_req,D_req;
logic [31:0] I_addr,D_addr;


always @(posedge ACLK or posedge rst) begin
  if(rst)begin
    state_DM <= IDLE_DM; 
    state_IM <= IDLE_IM;
  end else begin
      state_DM <= next_state_DM;
      state_IM <= next_state_IM;
  end
end
// assign DM_inst_reg = ((state_DM == R_READY_DM && next_state_DM == IDLE_DM) || (state_DM == IDLE_DM && next_state_DM == AR_VALID_DM))?2'd0:DM_inst_type;

always_comb begin//DM FSM master
    case(state_DM)
        IDLE_DM:begin
            if (DM_inst_type == 2'b11) begin
                next_state_DM = AW_VALID_DM;
            end else if (DM_inst_type == 2'b10 && D_req) begin
                next_state_DM = AR_VALID_DM;
            end else begin
                next_state_DM = IDLE_DM;
            end  
        end
        AW_VALID_DM:begin
           if (AWREADY_M1 && AWVALID_M1) begin
                next_state_DM = AW_DONE_DM;
           end else begin
                next_state_DM = AW_VALID_DM;
           end
        end
        AW_DONE_DM:begin
                next_state_DM = W_VALID_DM;           
        end
        W_VALID_DM:begin
            if (WLAST_M1) begin
                if (WVALID_M1 && WREADY_M1) begin
                    next_state_DM = B_WAIT_DM;
                end else begin
                    next_state_DM = W_VALID_DM;
                end 
            end else begin
                next_state_DM = AW_DONE_DM;
            end    
        end
        B_WAIT_DM:begin
            if (BVALID_M1) begin
                next_state_DM = B_READY_DM;
            end else begin
                next_state_DM = B_WAIT_DM;
            end
        end
        B_READY_DM:begin
            if (BVALID_M1 && BREADY_M1) begin
                next_state_DM = IDLE_DM;    
            end else begin
                next_state_DM = B_READY_DM;
            end
            
        end
        AR_VALID_DM:begin
            if (ARREADY_M1 && ARVALID_M1) begin
                next_state_DM = R_WAIT_DM;
            end else begin
                next_state_DM = AR_VALID_DM;
            end
        end
        R_WAIT_DM:begin
            if (RVALID_M1) begin
                next_state_DM = R_READY_DM;
            end else begin
                next_state_DM = R_WAIT_DM;
            end
        end
        R_READY_DM:begin//要把資料打CPU
            if (RREADY_M1 && RVALID_M1) begin
                if (RLAST_M1) begin
					next_state_DM = IDLE_DM;
				end else begin
					next_state_DM = R_WAIT_DM;
				end
            end else begin
                next_state_DM = R_READY_DM;
            end        
        end
        default:begin
            next_state_DM = IDLE_DM;
        end
    endcase
end

//IM FSM
always_comb begin
    case (state_IM)
        IDLE_IM:begin
            next_state_IM = (I_req)? AR_VALID_IM : IDLE_IM; 
        end
        AR_VALID_IM:begin
            if (ARREADY_M0) begin
                next_state_IM = R_WAIT_IM;
            end else begin
                next_state_IM = AR_VALID_IM;
            end
        end
        R_WAIT_IM:begin
             if (RVALID_M0) begin
                next_state_IM = R_READY_IM;
             end else begin
                next_state_IM = R_WAIT_IM;
             end
        end
        R_READY_IM:begin
            if (RREADY_M0 && RVALID_M0) begin
                if (RLAST_M0) begin
                  next_state_IM = IDLE_IM;  
                end else begin
                  next_state_IM = R_WAIT_IM; 
                end               
            end else begin
                next_state_IM = R_READY_IM;
            end
        end
        default:begin
                next_state_IM = IDLE_IM;
        end
    endcase
end

//AW_M1訊號控制
assign AWID_M1 = 4'd0;
always @(posedge ACLK or posedge rst) begin
    if (rst) begin
        awaddr_DM <= 32'd0;
    end else begin
        if (state_DM == IDLE_DM) begin
            awaddr_DM <= alu_out_reg3;
        end else begin
            awaddr_DM <= awaddr_DM;
        end
    end
end
assign AWADDR_M1 = awaddr_DM;
assign AWLEN_M1 = 4'd0;
assign AWSIZE_M1 = 3'b010;
assign AWBURST_M1 = 2'b01;
assign AWVALID_M1 = (state_DM == AW_VALID_DM);
//W_M1訊號控制
always @(posedge ACLK or posedge rst) begin
    if (rst) begin
        wdata_DM <= 32'd0;
        wstrb_DM <= 4'd0;
    end else begin
        if (AWREADY_M1 && AWVALID_M1) begin
            wdata_DM <= rs2_out_reg3;
            wstrb_DM <= wstrb;
        end else begin
            wstrb_DM <= wstrb_DM;
        end
    end
end

assign WSTRB_M1 = wstrb_DM;
assign WDATA_M1 = wdata_DM;
// assign WSTRB_M1 = 4'b1111;//要改成看STORE出來的訊號32bits會如何變成4bit去控制開關，暫時全開

always @ (posedge ACLK or posedge rst )begin
    if (rst) begin
        W_DATA_count <= 4'd0;
    end else begin
        if (state_DM == IDLE_DM) begin
            W_DATA_count <= 4'd0;
        end else begin
            if (WVALID_M1 && WREADY_M1) begin
            W_DATA_count <= W_DATA_count + 4'd1;
        end else
            W_DATA_count <= W_DATA_count;  
        end 
    end
end
assign WLAST_M1 = (state_DM == W_VALID_DM && (AWLEN_M1 == W_DATA_count));
assign WVALID_M1 = (state_DM == W_VALID_DM);
//B_M1 訊號控制
assign BREADY_M1 = (state_DM == B_READY_DM);

//AR_M1訊號控制
assign ARID_M1 = 4'd0;
always @(posedge ACLK or posedge rst) begin
    if (rst) begin
        araddr_DM <= 32'd0;
    end else begin
        if (state_DM == IDLE_DM) begin
            //araddr_DM <= {{16'd1},{alu_out_reg3[15:0]}};
            araddr_DM <= alu_out_reg3;
        end else begin
            araddr_DM <= araddr_DM;
        end
    end
end

assign ARADDR_M1 = D_addr;
assign ARLEN_M1  = (DM_inst_type == 2'b11)?4'd0:(DM_inst_type == 2'b10)?4'd3:4'd0;
assign ARSIZE_M1 = 3'b010;
assign ARBURST_M1 = 2'b01;
assign ARVALID_M1 = (state_DM == AR_VALID_DM);

//R_M1
assign RREADY_M1 = (state_DM == R_READY_DM);

always @ (posedge ACLK or posedge rst ) begin
    if (rst) begin
        DM_do_data <= 32'd0;
    end else begin
        if (ARVALID_M1 && ARREADY_M1) begin
            DM_do_data <= 32'd0;
        end else begin
            if (state_DM == R_READY_DM) begin
                DM_do_data <= RDATA_M1;
            end else begin
                DM_do_data <= DM_do_data;
            end
        end
    end
end

// assign DM_do = (state_DM == R_READY_DM )?RDATA_M1:DM_do_data;

//DM_DATA_out資料會鎖住回傳給CPU

//AR_M0訊號控制
assign ARID_M0 = 4'd0;

// logic [31:0]I_addr_reg;
// always @(posedge ACLK or posedge rst) begin
//     if(rst) begin
//         I_addr_reg <= 32'd0;
//     end else begin
//         I_addr_reg <= (state_IM)I_addr
//     end
// end
assign ARADDR_M0 = I_addr;
assign ARLEN_M0 = 4'd3;
assign ARSIZE_M0 = 3'b010;
assign ARBURST_M0 = 2'b01;
assign ARVALID_M0 = (state_IM == AR_VALID_IM);

//R_M0訊號控制
assign RREADY_M0 = (state_IM == R_READY_IM);
logic I_wait;
always @(posedge ACLK or posedge rst) begin
    if (rst) begin
        I_wait <= 1'b0;
    end else if (RREADY_M0 && RVALID_M0 && RLAST_M0) begin
        I_wait <= 1'b0;
    end else begin
        I_wait <= (I_req)?1'b1:I_wait;
    end
end

always @(posedge ACLK or posedge rst) begin
    if (rst) begin
        IM_cache_cnt <= 2'd0;
    end else if(state_IM == IDLE_IM) begin
        IM_cache_cnt <= 2'd0;
    end  else if(state_IM == R_READY_IM) begin
        IM_cache_cnt <= IM_cache_cnt + 2'd1;
    end 
end

always @(posedge ACLK or posedge rst) begin
    if (rst) begin
        DM_cache_cnt <= 2'd0;
    end else if(state_DM == IDLE_DM) begin
        DM_cache_cnt <= 2'd0;
    end else if(RREADY_M1 && RVALID_M1) begin
        DM_cache_cnt <= DM_cache_cnt + 2'd1;
    end
end

always @(posedge ACLK or posedge rst) begin
    if(rst)begin
        IM_cache_data_pack <= 128'd0;        
    end else if (state_IM == AR_VALID_IM) begin
        IM_cache_data_pack <= 128'd0;
    end else if (state_IM == R_READY_IM)  begin
        if(IM_cache_cnt == 2'd0) begin
            IM_cache_data_pack[31:0]   <= RDATA_M0;
        end else if(IM_cache_cnt == 2'd1) begin
            IM_cache_data_pack[63:32]  <= RDATA_M0;
        end else if(IM_cache_cnt == 2'd2) begin
            IM_cache_data_pack[95:64]  <= RDATA_M0;
        end else if(IM_cache_cnt == 2'd3) begin
            IM_cache_data_pack[127:96] <= RDATA_M0;
        end else begin
            IM_cache_data_pack <= IM_cache_data_pack;
        end
    end else 
        IM_cache_data_pack <= IM_cache_data_pack;
end

always @(posedge ACLK or posedge rst) begin
    if(rst)begin
        DM_cache_data_pack <= 128'd0;
    end else if(state_DM == AR_VALID_DM)  begin
        DM_cache_data_pack <= 128'd0;       
    end else if(state_DM == R_READY_DM)   begin
        if(DM_cache_cnt == 2'd0) begin
            DM_cache_data_pack[31:0]   <= RDATA_M1;
        end else if(DM_cache_cnt == 2'd1) begin
            DM_cache_data_pack[63:32]  <= RDATA_M1;
        end else if(DM_cache_cnt == 2'd2) begin
            DM_cache_data_pack[95:64]  <= RDATA_M1;
        end else if(DM_cache_cnt == 2'd3) begin
            DM_cache_data_pack[127:96] <= RDATA_M1;
        end else begin
            DM_cache_data_pack <= DM_cache_data_pack;
        end
    end else
        DM_cache_data_pack <= DM_cache_data_pack;
end

// assign IM_do = (RREADY_M0 && RVALID_M0)?RDATA_M0:32'd0;

always @(posedge ACLK or posedge rst) begin
    if(rst) begin
        IM_do <= 32'd0;
    end else if (state_IM == AR_VALID_IM) begin
        IM_do <= 32'd0;
    end else if (RREADY_M0 && RVALID_M0)  begin
        IM_do <= RDATA_M0;
    end else begin
        IM_do <= IM_do;
    end
end

always @(posedge ACLK or posedge rst) begin
    if(rst) begin
        DM_do <= 32'd0;
    end else if (state_DM == AR_VALID_DM) begin
        DM_do <= 32'd0;
    end else if (RREADY_M1 && RVALID_M1)  begin
        DM_do <= RDATA_M1;
    end else begin
        DM_do <= DM_do;
    end
end


logic core_wait_IM_cache;
logic core_wait_DM_cache;
logic DATA_RENEW_DONE;
logic B_DONE;

assign stop_IM = (state_IM == AR_VALID_IM || state_IM == R_WAIT_IM ||state_IM == R_READY_IM);
assign stop_IM_with_cache = (stop_IM || core_wait_IM_cache);
// assign stop_DM_with_cache =(DATA_RENEW_DONE)?1'b0:(stop_DM || core_wait_DM_cache);
assign B_DONE = (BREADY_M1 && BVALID_M1);
assign stop_DM_with_cache =(DATA_RENEW_DONE)?1'b0:(B_DONE)?1'b0:(stop_DM || core_wait_DM_cache);
// assign stop_DM = (state_DM == AR_VALID_DM || state_DM == R_WAIT_DM || state_DM == R_READY_DM || state_DM == AW_VALID_DM || state_DM == AW_DONE_DM || state_DM == W_VALID_DM || state_DM == B_WAIT_DM || state_DM == B_READY_DM));
// assign DM_inst_reg = (RLAST_M1)
always_comb begin
    if ((RREADY_M1 && RVALID_M1 && RLAST_M1)||(WREADY_M1 && WVALID_M1)) begin
        stop_DM = 1'd0;
    end else if ((DM_inst == 2'b10)||(DM_inst == 2'b11)) begin
        stop_DM = 1'd1; 
    end else begin
        stop_DM = 1'd0; 
    end
end

// logic D_wait;
// always_comb begin
//     if(DM_inst == 2'b10 || DM_inst == 2'b11) begin
//         D_wait = 1'd1;
//     end
// end
// assign data_to_cpu_IF

CPU CPU(
    .clk(ACLK),
    .rst(rst),
    .IM_do(I_cache_core_out),
    .DM_do(D_cache_core_out),
    .stop_DM(stop_DM_with_cache),
    .stop_IM(stop_IM_with_cache),
    .DMA_Interrupt(interrupt),
    .WTO(WTO),
    //output
    .pc_out(PC_for_IM),
    .DM_addr(alu_out_reg3),
    .DM_data(rs2_out_reg3),
    .DM_inst_type(DM_inst_type),
    .DM_inst(DM_inst),
    .DM_WSTRB(wstrb),
    .WFI_take_reg(WFI_take_reg)
);



IM_cache IM_cache(
    //input
    .clk(ACLK),
    .rst(rst),
    .core_addr(PC_for_IM),
    .I_out(IM_cache_data_pack),
    .I_wait(stop_IM),
    .WFI_take_reg(WFI_take_reg),
    //output
    .core_out(I_cache_core_out),
    .core_wait(core_wait_IM_cache),
    .I_req(I_req),
    .I_addr(I_addr)
);

DM_cache DM_cache(
    //input
    .clk(ACLK),
    .rst(rst),
    .core_addr(alu_out_reg3),
    .core_in(rs2_out_reg3),
    .core_inst(DM_inst_type),
    .wstrb(wstrb),
    .D_in(DM_cache_data_pack),
    .D_wait(stop_DM),
    .B_DONE(B_DONE),
    //output
    .core_out(D_cache_core_out),
    .D_req(D_req),
    .D_addr(D_addr),
    .core_wait(core_wait_DM_cache),
    .DATA_RENEW_DONE(DATA_RENEW_DONE)
);
endmodule
