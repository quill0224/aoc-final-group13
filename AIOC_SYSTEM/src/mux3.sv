module mux3 (

    input [31:0]   mux3_i0,
    input [31:0]   mux3_i1,
    input [31:0]   mux3_i2,
    input [31:0]   mux3_i3,

    input [1:0]    E_rs1_data_sel,

    output logic [31:0]  mux3_out

);
 always@(*) begin
    case (E_rs1_data_sel)
        2'd0:begin
            mux3_out = mux3_i0;
        end 
        2'd1:begin
            mux3_out = mux3_i1;
        end
        2'd2:begin
            mux3_out = mux3_i2;
        end 
        2'd3:begin
            mux3_out = mux3_i3;
        end       
    endcase
 end



endmodule