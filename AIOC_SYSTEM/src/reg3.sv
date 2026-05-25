module reg3 (
    input logic [31:0] alu_result,
    input logic [31:0] rs2_data,
    input logic        reg_web,stop_DM,
    input logic [6:0] E_op,
    input logic [2:0] E_f3,fe,
    input logic [4:0] E_rd,
    input       [31:0] pc2,    

    

    input clk,
    input rst,
    output logic [31:0] alu_out,
    output logic [31:0] rs2_out,
    output logic        reg_web_out,
    output logic [6:0] M_op,
    output logic [2:0] M_f3,fm,
    output logic [4:0] M_rd,
    output logic [31:0] pc3

);
always @(posedge clk or posedge rst) begin
    if (rst) begin
        alu_out <= 32'b0;
        rs2_out <= 32'b0;
        reg_web_out <= 1'b0;
        M_op <= 7'b0;
        M_f3 <= 3'b0;
        M_rd <= 5'b0;//多一位表f or not f
        pc3 <= 32'd0;
        fm <= 3'd0;
    end else begin
        if (stop_DM) begin
           alu_out <= alu_out;
           rs2_out <= rs2_out;
           reg_web_out <= reg_web_out;
           M_op <= M_op;
           M_f3 <= M_f3;
           M_rd <= M_rd;
           pc3 <= pc3;
           fm <= fm; 
        end else begin
        alu_out <= alu_result;
        rs2_out <= rs2_data;
        reg_web_out <= reg_web;
        M_op <= E_op;
        M_f3 <= E_f3;
        M_rd <= E_rd;//多一位表f or not f
        pc3 <= pc2;
        fm <= fe;
        end
    end
end
    
endmodule