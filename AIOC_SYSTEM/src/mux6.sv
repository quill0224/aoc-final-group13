module mux6 (
    input [31:0]   mux6_i0,
    input [31:0]   mux6_i1,
    input          E_alu_op2_sel,

    output logic [31:0]  mux6_out
);

 always@(*) begin
    if (!E_alu_op2_sel) begin
        mux6_out = mux6_i0;        
    end else begin
        mux6_out = mux6_i1;
    end
 end
    
endmodule