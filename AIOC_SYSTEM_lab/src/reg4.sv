module reg4 (
    input        [31:0] alu_out_in,
    input        [6:0] M_op,
    input        [4:0] M_rd,
    input        [2:0] M_f3,
    input        reg_web,
    input        clk,
    input        rst,
    input        [31:0] pc3,
    input        [2:0] fm,
    input              stop_DM,
    input        [31:0] DM_do,

    output logic [31:0] alu_out_out,
    output logic reg_web_out,
    output logic [6:0] W_op,
    output logic [4:0] W_rd,
    output logic [2:0] W_f3,
    output logic [31:0] pc4,DM_do_reg4,
    output logic [2:0]  fw
 

);


always @(posedge clk or posedge rst) begin
    if (rst) begin
        alu_out_out <= 32'd0;
        reg_web_out <= 1'd0;
        W_op <= 7'd0;
        W_rd <= 5'd0;
        W_f3 <= 3'd0;
        pc4 <= 32'd0;
        fw <= 3'd0;
        DM_do_reg4 <= 32'd0;
    end else begin if (stop_DM) begin
        alu_out_out <= 32'd0;
        reg_web_out <= 1'd0;
        W_op <= 7'd0;
        W_rd <= 5'd0;
        W_f3 <= 3'd0;
        pc4 <= 32'd0;
        fw <= 3'd0;
        DM_do_reg4 <= 32'd0;   
    end else begin
        alu_out_out <= alu_out_in;
        reg_web_out <= reg_web;
        W_op <= M_op;
        W_rd <= M_rd;
        W_f3 <= M_f3;
        pc4 <= pc3;
        fw <= fm;
        DM_do_reg4 <= DM_do;
    end
        
    end
end
endmodule

