module mux8(
    input   [31:0] s1,
    input   [31:0] LD_out,
    input   W_wb_data_sel,
    output logic [31:0] mux8_out
);

always @(*) begin
    if (!W_wb_data_sel) begin
        mux8_out = s1;
    end else begin
        mux8_out = LD_out;
    end
end
endmodule