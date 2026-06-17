//dma
module DMA (
    
    input        clk,
    input        rst,

    //CPU Interface
    input        DMAEN,
    input [31:0] DESC_BASE,
    input        S3_W_HS,
    input        M2_R_HS,
    input        M2_W_HS,
    input        WEB,

    input [31:0] r_ctrl,
    input        r_ctrl_choose, //1'b0: DMAEN   1'b1: DESC_BASE
    input [31:0] r_desc,
    input  [2:0] r_desc_choose, //2'b00: DMASRC  2'b01: DMADST   2'b10: DMALEN  2'b11: NEXT_DESC (wrapper的counter來決定當前是哪個值進來)
    input [31:0] r_data,  //讀DMASRC的資料
    
    
    input        fetch_finish,
    //input        read_finish,
    input        B_HS,

    output [31:0] w_data,
    output        fetch_flag,     //讀取描述符請求
    output        busy_flag,      //DMA忙碌旗標
    output        done_flag,
    output        empty_out,
    
    output [31:0] DMASRC_out,
    output [31:0] DMADST_out,
    output [31:0] DMALEN_out,
    output [31:0] DESC_out,       

    output DMA_interrupt
);
    
//logic fetch_finish;
//logic EOC;
logic [31:0] done_len;


logic        DMAEN_mem;
logic [31:0] DESC_BASE_mem;

logic [31:0] DMASRC_mem;
logic [31:0] DMADST_mem;
logic [31:0] DMALEN_mem;
logic [31:0] NEXT_DESC_mem;
logic [31:0] EOC_mem;

logic [31:0] DMASRC_reg;
logic [31:0] DMADST_reg;
logic [31:0] DMALEN_reg;
logic [31:0] NEXT_DESC_reg;
logic [31:0] EOC_reg;

//assign EOC = NEXT_DESC[31];


//===== FSM ====
logic [2:0] state, nextstate;

parameter IDLE        = 3'd0;
parameter FETCH_DESC  = 3'd1;
parameter EXECUTE     = 3'd2;
parameter DONE        = 3'd3;
parameter CHECK_CHAIN = 3'd4;
parameter FINISH      = 3'd5;

always_ff @(posedge clk or posedge rst) begin
    if (rst) begin

        state <= IDLE;

    end else begin

        state <= nextstate;
    end
end

always_comb begin
    case (state)
        IDLE : 
            if (r_ctrl_choose==1'b1) 

                nextstate = FETCH_DESC;
            else 
                nextstate = IDLE;
        FETCH_DESC :
            if (fetch_finish) begin
                
                nextstate = EXECUTE;

            end else begin

                nextstate = FETCH_DESC;
            end
        EXECUTE :
            if (done_len == DMALEN_mem) begin
                
                nextstate = CHECK_CHAIN;

            end else if (B_HS) begin

                nextstate = DONE;

            end else begin

                nextstate = EXECUTE;
            end
        DONE : 
                nextstate = EXECUTE;
        CHECK_CHAIN : 
            if ((EOC_mem == 32'd1) && (DMAEN_mem == 1'b0)) 

                nextstate = FINISH;
            else 
                nextstate = FETCH_DESC;
        FINISH :
                nextstate = IDLE;

        default: nextstate = IDLE;
    endcase
end

/////////////////////////////////////////////////把CPU的control signal抓回來//////////////////////
always_ff @( posedge clk or posedge rst ) begin
    if (rst) begin

        DESC_BASE_mem <= 32'd0;
        DMAEN_mem     <= 1'b0;

    end else if (S3_W_HS && (r_ctrl == 32'h2ff00))begin

        DESC_BASE_mem    <= ( (r_ctrl_choose == 1'b0) & (!WEB)) ? r_ctrl : DESC_BASE_mem;
        DMAEN_mem        <= ( (r_ctrl_choose == 1'b1) & (!WEB)) ? r_ctrl[0] : DMAEN_mem;

    end else begin

        DESC_BASE_mem <= DESC_BASE_mem;
        DMAEN_mem     <= DMAEN_mem;
    end
end

////////////////////////////////////////////////把desc_lost的一組address抓回來//////////////////////
always_ff@( posedge clk or posedge rst ) begin
    if(rst) begin

        DMASRC_mem <= 32'd0;
        DMADST_mem <= 32'd0;
        DMALEN_mem <= 32'd0;
        NEXT_DESC_mem <= 32'd0;
        EOC_mem    <= 32'd0;
    end
    else if ((state == FETCH_DESC) && (M2_R_HS)) begin
        //DMAEN_mem  <= ( (w_data_choose==2'b00)) ? w_data[0] : DMAEN_mem;
        DMASRC_mem    <= ( (r_desc_choose == 3'b000) ) ? r_desc : DMASRC_mem;
        DMADST_mem    <= ( (r_desc_choose == 3'b001) ) ? r_desc : DMADST_mem;
        DMALEN_mem    <= ( (r_desc_choose == 3'b010) ) ? r_desc : DMALEN_mem;
        NEXT_DESC_mem <= ( (r_desc_choose == 3'b011) ) ? r_desc : NEXT_DESC_mem;
        EOC_mem       <= ( (r_desc_choose == 3'b100) ) ? r_desc : EOC_mem;
    end
end

/////////////////////FIFO//////////////////////////////



logic        wr_en;
//logic [31:0] din; (input r_data)
logic        full;
logic        rd_en;
logic [31:0] dout;
logic        empty;
logic [31:0] mem [15:0];
logic [3:0]  wptr;
logic [3:0]  rptr;
logic [4:0]  count;
logic        do_write;
logic        do_read;
logic [3:0]  count_count;

assign wr_en = (M2_R_HS && !fetch_flag);
assign rd_en = M2_W_HS;

assign full  = (count == 5'd16);
assign empty = (count == 5'd0);

assign do_write = (wr_en & !full );
assign do_read  = (rd_en & !empty);

always @(posedge clk or posedge rst) begin
    if(rst)

        count <= 5'd0;
    else if (state == DONE || state == CHECK_CHAIN || state == FETCH_DESC)      //每換 descriptor 
    
        count <= 5'd0;
    else begin
        case ({do_write, do_read})
            2'b10: count <= count + 5'd1;   // 寫
            2'b01: count <= count - 5'd1;   // 讀
            default: count <= count;        // 同時 或 都不動
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if(rst)

        wptr <= 4'd0;

    else if (state == DONE || state == CHECK_CHAIN || state == FETCH_DESC)
        
        wptr <= 4'd0;

    else if(do_write)

        wptr <= (wptr == 4'd15) ? 4'd0 : (wptr + 4'd1);
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rptr <= 4'd0;
    end
    else if (state == DONE || state == CHECK_CHAIN || state == FETCH_DESC) begin
        rptr <= 4'd0;
    end
    else if (do_read) begin
        rptr <= (rptr == 4'd15) ? 4'd0 : (rptr + 4'd1);
    end
end

assign dout = mem[rptr];

always @(posedge clk or posedge rst) begin
    if(rst)begin
        for (integer i=0 ;i<16 ;i++ ) begin
            mem[i] <= 32'd0;
        end
    end else if(do_write)
        mem[wptr] <= r_data;            //r_data會被寫進去FIFO
end

// always @(posedge clk or posedge rst) begin
//     if(rst)

//         count_count <= 4'd0;

//     else if(count == 5'd16)

//         count_count <= count_count + 4'd1;
// end

////////////////////////////////////////////////////////


always_ff@(posedge clk or posedge rst) begin
    if(rst) begin
        
        DMASRC_reg  <= 32'd0;
        DMADST_reg  <= 32'd0;
        DMALEN_reg  <= 32'd0;
        done_len    <= 32'd0;
    
    end else begin
        done_len   <= (state == IDLE || state == FETCH_DESC) ? 32'd0 :
                      (state == DONE) ? (done_len + DMALEN_reg + 32'd1) : done_len;   
        
        DMASRC_reg <= (state == FETCH_DESC) ? DMASRC_mem :
                      (state == DONE) ? 
                      ( (DMALEN_mem - done_len >= 32'd16) ? (DMASRC_reg + 32'd64) : (DMASRC_reg + ((DMALEN_mem - done_len) << 2) ) ) : DMASRC_reg;

        DMADST_reg <= (state == FETCH_DESC) ? DMADST_mem :
                      (state == DONE) ? 
                      ( (DMALEN_mem - done_len >= 32'd16) ? (DMADST_reg + 32'd64) : (DMADST_reg + ((DMALEN_mem - done_len) << 2) ) ) : DMADST_reg;

        DMALEN_reg <= ( state == DONE) ? 
                      ( ( (DMALEN_mem - done_len - DMALEN_reg) >= 32'd17) ? 32'd15 : (DMALEN_mem - done_len - DMALEN_reg - 32'd2) ) :
                      (state == FETCH_DESC ) ? 
                      ( (DMALEN_mem - done_len >= 32'd15) ? 32'd15 : (DMALEN_mem - done_len - 32'd1) ) : 
                      (state == DONE) ? 32'd0 : DMALEN_reg;
    end
        
end

logic start_desc;

always_ff @( posedge clk or posedge rst ) begin
    if (rst) begin
        
        start_desc <= 1'd0;
        
    end else if ((DESC_BASE_mem == 32'h2ff00) && (NEXT_DESC_mem == 32'd0)) begin
        
        start_desc <= 1'd1;

    end else begin
        
        start_desc <= 1'd0;
    end
end

assign fetch_flag    = (state == FETCH_DESC) ? 1'b1 : 1'b0;

assign DMADST_out    = DMADST_reg;
assign DMASRC_out    = DMASRC_reg;
assign DMALEN_out    = DMALEN_reg;
assign DESC_out      = ((state == FETCH_DESC) && !start_desc) ? NEXT_DESC_mem : DESC_BASE_mem;
assign empty_out     = empty;

assign w_data        = dout;
assign busy_flag     = ((state == EXECUTE) && (done_len != DMALEN_mem)) ? 1'b1 : 1'b0;
assign done_flag     = (done_len == DMALEN_mem);
assign DMA_interrupt = (state == FINISH) ? 1'b1 : 1'b0;

endmodule