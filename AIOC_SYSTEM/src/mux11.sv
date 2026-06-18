module mux11 (

    input [31:0]   mux11_i0,
    input [31:0]   mux11_i1,
    input          FD_rs1_data_sel,

    output logic [31:0]  mux11_out

);
 always@(*) begin
    if (FD_rs1_data_sel) begin
        mux11_out = mux11_i1;        
    end else begin
        mux11_out = mux11_i0;
    end
 end



endmodule