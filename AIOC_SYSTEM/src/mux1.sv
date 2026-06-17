module mux1 (
    input [31:0]   mux1_i1,
    input [31:0]   mux1_i2,
    input          D_rs1_data_sel,

    output logic [31:0]  mux1_out

);
 always@(*) begin
    if (D_rs1_data_sel) begin
        mux1_out = mux1_i2;        
    end else begin
        mux1_out = mux1_i1;
    end
 end

endmodule