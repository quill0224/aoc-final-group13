module async_CDC_16  (
    input                           clk,   //寫入FIFO
    input                           rst,
    input                           clk2,  //讀出FIFO
    input                           rst2,
    input   [49:0]                  w_data,
    input                           I_am_ready,   //接收端發ready signal
    input                           WEB,          //寫入端發valid signal

    output logic                    ready,        //判斷FIFO可不可以被寫入
    output logic                    valid,        //判斷FIFO有沒有東西可以被被讀出
    output logic [49:0]   DO
);

//---- register file (FIFO) ----
logic [49:0] DATA_FIFO [0:15];

//---- pointer ----
logic  [4:0]    w_ptr;
logic  [4:0]    r_ptr;
logic  [4:0]    w_ptr_gray;
logic  [4:0]    r_ptr_gray;
logic  [4:0]    w_ptr_f0_gray;
logic  [4:0]    r_ptr_f0_gray;
logic  [4:0]    w_ptr_f1_gray;
logic  [4:0]    w_ptr_f2_gray;
logic  [4:0]    r_ptr_f1_gray;
logic  [4:0]    r_ptr_f2_gray;



//full empty
logic full_flag;
logic empty_flag;

assign ready = (!full_flag);
assign valid = (!empty_flag);

assign w_ptr_gray = w_ptr ^ {1'd0 ,w_ptr[4:1]};
assign r_ptr_gray = r_ptr ^ {1'd0 ,r_ptr[4:1]};

// full的標準是看寫入端(clk), w_ptr_gray跟同步過來的r_ptr_f2_gray比較
assign full_flag  = ( (( ~r_ptr_f2_gray[4:3]) == w_ptr_gray[4:3]) && (r_ptr_f2_gray[2:0] == w_ptr_gray[2:0]) ) ? 1'b1 : 1'b0;

// empty的標準是看讀出端(clk2), r_ptr_gray跟同步過來的w_ptr_f2_gray比較
assign empty_flag = ( (   w_ptr_f2_gray[4:3]  == r_ptr_gray[4:3]) && (w_ptr_f2_gray[2:0] == r_ptr_gray[2:0]) ) ? 1'b1 : 1'b0;



//Turn read to write domain
always_ff @( posedge clk2 or posedge rst2 ) begin
    if(rst2) begin

        r_ptr_f0_gray <= 5'd0;
       
    end
    else begin

        r_ptr_f0_gray <= r_ptr_gray;
    end
end

always_ff @( posedge clk or posedge rst ) begin
    if(rst) begin

        r_ptr_f1_gray <= 5'd0;
        r_ptr_f2_gray <= 5'd0;
    end
    else begin

        r_ptr_f1_gray <= r_ptr_f0_gray;
        r_ptr_f2_gray <= r_ptr_f1_gray;
    end
end

//Turn write to read domain
always_ff @( posedge clk or posedge rst ) begin
    if(rst) begin

        w_ptr_f0_gray <= 5'd0;
    end
    else begin

        w_ptr_f0_gray <= w_ptr_gray;
    end
end


always_ff @( posedge clk2 or posedge rst2 ) begin
    if(rst2)begin

        w_ptr_f1_gray <= 5'd0;
        w_ptr_f2_gray <= 5'd0;
    end
    else begin

        w_ptr_f1_gray <= w_ptr_f0_gray;
        w_ptr_f2_gray <= w_ptr_f1_gray;
    end
end

//===================================//
//          Write Data               //
//===================================//
always_ff @( posedge clk or posedge rst ) begin
    if(rst) begin

        DATA_FIFO[0] <= 50'd0;
        DATA_FIFO[1] <= 50'd0;
        DATA_FIFO[2] <= 50'd0;
        DATA_FIFO[3] <= 50'd0;
        DATA_FIFO[4] <= 50'd0;
        DATA_FIFO[5] <= 50'd0;
        DATA_FIFO[6] <= 50'd0;
        DATA_FIFO[7] <= 50'd0;
        DATA_FIFO[8] <= 50'd0;
        DATA_FIFO[9] <= 50'd0;
        DATA_FIFO[10] <= 50'd0;
        DATA_FIFO[11] <= 50'd0;
        DATA_FIFO[12] <= 50'd0;
        DATA_FIFO[13] <= 50'd0;
        DATA_FIFO[14] <= 50'd0;
        DATA_FIFO[15] <= 50'd0;
        w_ptr <= 5'd0;
    end
    else begin
        if(!full_flag && !WEB ) begin
            
            DATA_FIFO[w_ptr[3:0]] <= w_data;
            w_ptr <= w_ptr + 5'd1;
        end
        else begin

            w_ptr <= w_ptr;
        end
    end
end



//===================================//
//          Read Data                //
//===================================//
always_ff @( posedge clk2 or posedge rst2 ) begin
    if(rst2) begin

        r_ptr <= 5'd0;
    end
    else begin
        if(I_am_ready && !empty_flag) begin

            r_ptr <= r_ptr + 5'd1 ;
        end
        else begin

            r_ptr <= r_ptr;
        end
    end
end

//Output
assign DO = (!empty_flag) ? DATA_FIFO[r_ptr[3:0]] : 0 ;




endmodule