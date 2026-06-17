module mux5 (
    input [31:0]   mux5_i0,
    input [31:0]   mux5_i1,
    input          E_alu_op1_sel,

    output logic [31:0]  mux5_out
);

 always@(*) begin
    if (!E_alu_op1_sel) begin
        mux5_out = mux5_i0;        
    end else begin
        mux5_out = mux5_i1;
    end
 end
    
endmodule