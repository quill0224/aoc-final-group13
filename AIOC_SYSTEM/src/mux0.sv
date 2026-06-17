module mux0(
    input  [31:0] jb_pc,
    input  [31:0] pc_cycle,
    input  jb,stall,
    input  d_rst_bar,
    input  branch_result,
    output logic [31:0] mux0_out

);

always @(*) begin
    if (d_rst_bar) begin
        mux0_out = 32'd0;        
    end else if(~stall) begin
            if (jb) begin
                mux0_out = jb_pc;
            end else begin
                mux0_out = pc_cycle + 4;
            end
        end else begin
        mux0_out = pc_cycle;
    end
end

endmodule