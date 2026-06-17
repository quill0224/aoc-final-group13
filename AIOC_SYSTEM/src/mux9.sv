module mux9 (
    input  alu_jb_sel,
    input  [31:0] alu_out,
    input  [31:0] jb_out,
    input  [31:0] CSR_out,
    input  [6:0]  opcode,
    output logic [31:0] mux9_out
);
always @(*) begin
    if (opcode ==7'b1110011) begin
        mux9_out = CSR_out;
    end else begin
        if (alu_jb_sel) begin
            mux9_out = jb_out;
        end else begin
            mux9_out = alu_out;
        end 
    end
end
endmodule