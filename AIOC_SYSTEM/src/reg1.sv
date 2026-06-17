module reg1 (
    input [31:0]        pc1,
    input               clk,
    input               rst,
    input               stall,
    input               jb,
    input               stop_DM,
    input               stop_IM,
    input [31:0]        IM_do,
    input               Interrupt_take,WFI_take_reg,
    output logic [31:0] inst,
    output logic [31:0] pc1_out
);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        pc1_out <= 32'd0;
        inst    <= 32'd0;        
    end else begin
        if(stall||stop_DM ) begin
            pc1_out <= pc1_out;
            inst    <= inst;
        end else if (jb||stop_IM||Interrupt_take|| WFI_take_reg) begin
            pc1_out <= 32'd0;
            inst    <= 32'd0;
        end else begin 
        pc1_out <= pc1;
        inst    <= IM_do;          
        end  
    end
end




endmodule