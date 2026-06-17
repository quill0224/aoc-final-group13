module mux2 (

    input [31:0]   mux2_i1,
    input [31:0]   mux2_i2,
    input          D_rs2_data_sel,

    output logic [31:0]  mux2_out

);
 always@(*) begin
    if (D_rs2_data_sel) begin
        mux2_out = mux2_i2;        
    end else begin
        mux2_out = mux2_i1;
    end
 end



endmodule