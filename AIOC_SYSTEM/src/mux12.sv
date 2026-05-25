module mux12 (

    input [31:0]   mux12_i0,
    input [31:0]   mux12_i1,
    input          FD_rs2_data_sel,

    output logic [31:0]  mux12_out

);
 always@(*) begin
    if (FD_rs2_data_sel) begin
        mux12_out = mux12_i1;        
    end else begin
        mux12_out = mux12_i0;
    end
 end



endmodule