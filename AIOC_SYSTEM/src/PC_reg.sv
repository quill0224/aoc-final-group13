module PC_reg (
    input  clk,
    input  [31:0]in,CSR_pc,
    input  rst,
    input  stall,
    input stop_DM,
    input stop_IM,
    input branch_typ,branch_typ2,WFI_take_reg,Interrupt_return,Interrupt_take,
    output logic [31:0] pc_reg_out
);

logic [31:0] pc;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        pc <= 32'd0;
    end else if (Interrupt_return || Interrupt_take) begin
        pc <= CSR_pc;
    end else if ( stall || stop_DM || stop_IM ) begin
        pc <= pc;
    end else begin
        pc <= (WFI_take_reg)?32'd0:in;         
    end
end   
assign pc_reg_out = (branch_typ || branch_typ2)?32'h30000000:pc;

endmodule