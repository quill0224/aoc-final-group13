module reg2 (
    input [31:0]    pc2,
    input [31:0]    imm2,
    input [31:0]    rs1,
    input [31:0]    rs2,
    input [6:0]     opcode,
    input [2:0]     funct3,
    input [4:0]     rd_idx,
    input           clk,
    input           rst,
    input       jb,shamt,
    input    stall,stop_DM,Interrupt_take,WFI_take_reg,
    input  reg_web,
    input  branch_typ,
    input  [4:0] alu_code,r1_idx,r2_idx,
    //
    input [31:0] frs1_data,frs2_data,
    input [2:0]  f,
    input [1:0] lui_inst_ID,
    input [2:0] compare_inst_ID,
    input       orcb_ID,
    input [1:0] pack_inst_ID,


    output logic [31:0]   pc2_out,
    output logic [31:0]   imm_out,
    output logic [31:0]   rs1_out,
    output logic [31:0]   rs2_out,
    output logic    reg_web_out,shamt_ex,
    output logic    branch_typ2,
    output logic    [6:0] E_op,
    output logic    [2:0] E_f3,fe,
    output logic    [4:0] E_rd,
    output logic    [4:0] E_alu_code,
    output logic    [4:0] E_rs1,E_rs2,
    output logic [31:0]   frs1_out,frs2_out,
    output logic [1:0] lui_inst_EX,
    output logic [2:0] compare_inst_EX,
    output logic       orcb_EX,
    output logic [1:0] pack_inst_EX

);



always @(posedge clk or posedge rst ) begin
    if (rst) begin
		pc2_out <= 32'd0;
        imm_out <= 32'd0; 
        rs1_out <=32'd0;
        rs2_out <= 32'd0;
        frs1_out <= 32'd0;
        frs2_out <= 32'd0;
        reg_web_out <= 1'd0;   
        branch_typ2 <= 1'd0;
        E_op <= 7'd0;
        E_f3 <= 3'd0;
        E_rd <= 5'd0;
        E_alu_code <= 5'd0; 
        E_rs1 <= 5'd0;
        E_rs2 <= 5'd0;
        shamt_ex <= 1'd0;
        fe <= 3'd0;
        lui_inst_EX <= 2'd0;
        pack_inst_EX <= 2'd0;
        compare_inst_EX <= 3'd0;
        orcb_EX <= 1'b0;
	end else begin
        if ( stop_DM || WFI_take_reg ) begin
            pc2_out <= pc2_out;
            imm_out <= imm_out; 
            rs1_out <= rs1_out;
            rs2_out <= rs2_out;
            frs1_out <= frs1_out;
            frs2_out <= frs2_out;
            reg_web_out <= reg_web_out;   
            branch_typ2 <= branch_typ2;
            E_op <= E_op;
            E_f3 <= E_f3;
            E_rd <= E_rd;//多一位表f or not f
            E_alu_code <= E_alu_code; 
            E_rs1 <= E_rs1;//多一位表f or not f
            E_rs2 <= E_rs2;//多一位表f or not f
            shamt_ex <= shamt_ex;
            fe <= fe; 
            lui_inst_EX <= lui_inst_EX;
            pack_inst_EX <= pack_inst_EX;
            compare_inst_EX <= compare_inst_EX;
            orcb_EX <= orcb_EX; 
        end
		if (stall || jb || Interrupt_take) begin
            pc2_out <= 32'd0;
            imm_out <= 32'd0; 
            rs1_out <=32'd0;
            rs2_out <= 32'd0;
            frs1_out <= 32'd0;
            frs2_out <= 32'd0;
            reg_web_out <= 1'd0;   
            branch_typ2 <= 1'd0;
            E_op <= 7'd0;
            E_f3 <= 3'd0;
            E_rd <= 5'd0;//多一位表f or not f
            E_alu_code <= 5'd0; 
            E_rs1 <= 5'd0;//多一位表f or not f
            E_rs2 <= 5'd0;//多一位表f or not f
            shamt_ex <= 1'd0;
            fe <= 3'd0;
            lui_inst_EX <= 2'd0;
            pack_inst_EX <= 2'd0;
            compare_inst_EX <= 3'd0;
            orcb_EX <= 1'b0;
			end else begin
				pc2_out <= pc2;
				imm_out <= imm2; 
				rs1_out <= rs1;
				rs2_out <= rs2;
				frs1_out <= frs1_data;
				frs2_out <= frs2_data;
				reg_web_out <= reg_web;
				branch_typ2 <= branch_typ;
				E_op <= opcode;
				E_f3 <= funct3;
				E_rd <= rd_idx;//多一位表f or not f
				E_alu_code <= alu_code;
				E_rs1 <= r1_idx;//多一位表f(1) or not f(0)
				E_rs2 <= r2_idx;//多一位表f or not f
				shamt_ex <= shamt;
				fe <= f;
                lui_inst_EX <= lui_inst_ID;
                pack_inst_EX <= pack_inst_ID;
                compare_inst_EX <= compare_inst_ID;
                orcb_EX <= orcb_ID; 
			end		
		end
	end
	

endmodule