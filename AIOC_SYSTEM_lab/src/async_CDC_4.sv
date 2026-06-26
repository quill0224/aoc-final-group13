module async_CDC_4  (
    input                clk,   //寫入FIFO
    input                rst,

    input                clk2,  //讀出FIFO
    input                rst2,

    input        [49:0]  w_data,
    input                I_am_ready,   //接收端發ready signal
    input                WEB,          //寫入端發valid signal

    output logic         ready,        //full_or_not
    output logic         valid,        //empty_or_not
    output logic [49:0]  DO
);


//---- register file (FIFO) ----
logic [49:0] DATA_FIFO [0:3];

//---- pointer ----
logic  [2:0]    w_ptr;
logic  [2:0]    r_ptr;
logic  [2:0]    w_ptr_gray;
logic  [2:0]    r_ptr_gray;
logic  [2:0]    w_ptr_f0_gray;
logic  [2:0]    r_ptr_f0_gray;
logic  [2:0]    w_ptr_f1_gray;
logic  [2:0]    w_ptr_f2_gray;
logic  [2:0]    r_ptr_f1_gray;
logic  [2:0]    r_ptr_f2_gray;



//full empty
logic full_flag;
logic empty_flag;

assign ready = (!full_flag);
assign valid = (!empty_flag);


assign w_ptr_gray = w_ptr ^ {1'd0 ,w_ptr[2:1]};
assign r_ptr_gray = r_ptr ^ {1'd0 ,r_ptr[2:1]};

// full的標準是看寫入端(clk), w_ptr_gray跟同步過來的r_ptr_f2_gray比較
assign full_flag  = ( ( ( ~r_ptr_f2_gray[2:1]) == w_ptr_gray[2:1]) && (r_ptr_f2_gray[0] == w_ptr_gray[0]) ) ? 1'b1 : 1'b0;

// empty的標準是看讀出端(clk2), r_ptr_gray跟同步過來的w_ptr_f2_gray比較
assign empty_flag = ( (    w_ptr_f2_gray[2:1]  == r_ptr_gray[2:1]) && (w_ptr_f2_gray[0] == r_ptr_gray[0]) ) ? 1'b1 : 1'b0;



//Turn read to write domain
always_ff @( posedge clk2 or posedge rst2 ) begin
    if(rst2) begin

        r_ptr_f0_gray <= 3'd0;
       
    end
    else begin

        r_ptr_f0_gray <= r_ptr_gray;
    end
end

always_ff @( posedge clk or posedge rst ) begin
    if(rst) begin
        
        r_ptr_f1_gray <= 3'd0;
        r_ptr_f2_gray <= 3'd0;
    end
    else begin

        r_ptr_f1_gray <= r_ptr_f0_gray;
        r_ptr_f2_gray <= r_ptr_f1_gray;
    end
end

//Turn write to read domain
always_ff @( posedge clk or posedge rst ) begin
    if(rst) begin

        w_ptr_f0_gray <= 3'd0;
    end
    else begin

        w_ptr_f0_gray <= w_ptr_gray;
    end
end


always_ff @( posedge clk2 or posedge rst2 ) begin
    if(rst2)begin

        w_ptr_f1_gray <= 3'd0;
        w_ptr_f2_gray <= 3'd0;
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
        w_ptr <= 3'd0;
    end
    else begin
        if(!full_flag && !WEB ) begin

            DATA_FIFO[w_ptr[1:0]] <= w_data;
            w_ptr <= w_ptr + 3'd1;

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

        r_ptr <= 3'd0;
    end
    else begin
        if(I_am_ready && !empty_flag) begin

            r_ptr <= r_ptr + 3'd1 ;
        end
        else begin

            r_ptr <= r_ptr;
        end
    end
end

//Output
assign DO = (!empty_flag) ? DATA_FIFO[r_ptr[1:0]] : 0 ;




endmodule