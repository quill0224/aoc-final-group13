
module async_CDC_1 (
    input                           clk,   //寫入FIFO
    input                           rst,
    input                           clk2,  //讀出FIFO
    input                           rst2,
    input   [49:0]                  w_data,
    input                           I_am_ready,  //接收端發ready signal
    input                           WEB,         //寫入端發valid signal

    output logic                    ready,       //判斷FIFO可不可以被寫入
    output logic                    valid,       //判斷FIFO有沒有東西可以被被讀出
    output logic [49:0]   DO
);

//---- register file (FIFO) ----
logic [49:0] DATA_FIFO;

//---- pointer ----
logic  w_ptr;
logic  r_ptr;
logic  w_ptr_f0;
logic  r_ptr_f0;
logic  w_ptr_f1;
logic  w_ptr_f2;
logic  r_ptr_f1;
logic  r_ptr_f2;

//full empty
logic full_flag;
logic empty_flag;

assign ready = (!full_flag);
assign valid = (!empty_flag);

assign full_flag  = (r_ptr_f2 != w_ptr   ) ? 1'b1 : 1'b0;
assign empty_flag = (r_ptr    == w_ptr_f2) ? 1'b1 : 1'b0;

//Turn read to write
always_ff @( posedge clk2 or posedge rst2 ) begin
    if(rst2) begin

        r_ptr_f0 <= 1'b0;
       
    end
    else begin

        r_ptr_f0 <= r_ptr;
    end
end

always_ff @( posedge clk or posedge rst) begin
    if(rst) begin

        r_ptr_f1 <= 1'b0;
        r_ptr_f2 <= 1'b0;
    end
    else begin

        r_ptr_f1 <= r_ptr_f0;
        r_ptr_f2 <= r_ptr_f1;
    end
end

//Turn write to read
always_ff @( posedge clk or posedge rst ) begin
    if(rst) begin

        w_ptr_f0 <= 1'b0;
    end
    else begin

        w_ptr_f0 <= w_ptr;
    end
end


always_ff @( posedge clk2 or posedge rst2 ) begin
    if(rst2)begin

        w_ptr_f1 <= 1'b0;
        w_ptr_f2 <= 1'b0;
    end
    else begin

        w_ptr_f1 <= w_ptr_f0;
        w_ptr_f2 <= w_ptr_f1;
    end
end

//===================================//
//          Write Data               //
//===================================//
always_ff @( posedge clk or posedge rst ) begin
    if(rst) begin
        DATA_FIFO <= 50'd0;
        w_ptr <= 1'b0;
    end
    else begin
        if(!full_flag && !WEB ) begin

            DATA_FIFO <= w_data;
            w_ptr <= ~w_ptr;
        end
        else begin

            DATA_FIFO <= DATA_FIFO;
            w_ptr <= w_ptr;
        end
    end
end



//===================================//
//          Read Data                //
//===================================//
always_ff @( posedge clk2 or posedge rst2 ) begin
    if(rst2) begin

        r_ptr <= 1'b0;
    end
    else begin
        if(I_am_ready && !empty_flag) begin

            r_ptr <= ~r_ptr ;
        end
        else begin

            r_ptr <= r_ptr;
        end
    end
end

//Output
assign DO = (!empty_flag) ? DATA_FIFO : 0 ;

endmodule