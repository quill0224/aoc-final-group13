module Forward(
    input clk,
    input rst,
    input  [6:0] opcode,E_op,W_op,M_op, //解碼後的opcode,W_op,M_op;
    input  [4:0] E_rd,M_rd,W_rd,
    input  [4:0] dc_rs1,dc_rs2,
    input  [4:0] E_rs1,E_rs2,
    input  [2:0] M_f3,
    input  [31:0] alu_out_reg3,
    input  [2:0] fd,fe,fm,fw,



    output logic [1:0]  E_rs1_data_sel,E_rs2_data_sel,
    output logic        D_rs1_data_sel, D_rs2_data_sel,FD_rs1_data_sel,FD_rs2_data_sel,
    output logic        E_alu_op1_sel,E_alu_op2_sel,
    // output logic [31:0] M_dm_w_en,
    output logic        stall,
    output logic        DM_wb,
    output logic        W_wb_data_sel,
    output logic        f_W_wb_en
);

`define ALU         7'b0110011
`define LD          7'b0000011
`define ALUI        7'b0010011
`define JALR        7'b1100111
`define STYPE       7'b0100011
`define BTYPE       7'b1100011
`define APUIC       7'b0010111
`define LUI         7'b0110111
`define JTYPE       7'b1101111
`define FLW         7'b0000111
`define FSW         7'b0100111
`define CSR         7'b1110011
`define FAS         7'b1010011

logic is_W_use_rd,is_D_use_rs1,is_D_use_rs2;
logic [1:0] alu_hb_select;
logic is_E_use_rs1,is_E_use_rs2;
assign alu_hb_select = alu_out_reg3[1:0];

assign f_W_wb_en = (W_op == `FLW || W_op == `FAS);
//mux1,2的選擇控制
assign is_D_use_rs1 = (opcode == `ALU || opcode == `LD || opcode == `ALUI || opcode == `JALR || opcode == `STYPE || opcode == `BTYPE || opcode == `FLW || opcode == `FSW || opcode ==`CSR);
assign is_D_use_rs2 = (opcode == `ALU || opcode == `STYPE || opcode == `BTYPE || opcode == `FSW);

assign is_W_use_rd  = (W_op == `ALU || W_op == `LD || W_op == `ALUI || W_op == `JALR || W_op == `APUIC || W_op== `LUI   || W_op == `JTYPE || W_op == `FLW || W_op == `FAS || W_op == `CSR);
assign is_M_use_rd  = (M_op == `ALU || M_op == `LD || M_op == `ALUI || M_op == `APUIC || M_op == `LUI || M_op == `JTYPE || M_op == `JALR  || M_op == `FLW || M_op == `FAS || M_op == `CSR);

assign is_W_use_frd = (W_op == `FLW || W_op == `FAS);
//assign is_M_use_frd = (M_op == `FLW || M_op == `FAS);

assign D_rs1_data_sel =(is_D_use_rs1 & is_W_use_rd & ({{fd[2]},dc_rs1} == {{fw[0]},W_rd}) & W_rd != 5'd0 );
assign D_rs2_data_sel =(is_D_use_rs2 & is_W_use_rd & (dc_rs2 == W_rd) & W_rd != 5'd0 );

//mux3,4的選擇控制
assign is_E_use_rs1 = (E_op == `ALU || E_op == `LD || E_op == `ALUI || E_op == `STYPE || E_op == `BTYPE || E_op == `JALR || E_op == `FLW || E_op == `FSW || E_op == `FAS);
assign is_E_use_rs2 = (E_op == `ALU || E_op == `STYPE || E_op == `BTYPE || E_op == `FSW || E_op == `FAS);

//assign is_E_use_frs1 = (E_op == `FAS);
//assign is_E_use_frs2 = (E_op == `FSW || E_op == `FAS);

//rs1 overlap
assign is_E_rs1_W_rd_overlap = (is_E_use_rs1 & is_W_use_rd & ({{fe[2]},E_rs1} == {{fw[0]},W_rd}) & (W_rd != 5'b0));
assign is_E_rs1_M_rd_overlap = (is_E_use_rs1 & is_M_use_rd & ({{fe[2]},E_rs1} == {{fm[0]},M_rd}) & (M_rd != 5'b0));

// assign is_E_frs1_W_frd_overlap = (is_E_use_frs1 & is_W_use_frd & (E_frs1 == W_frd));
// assign is_E_frs1_M_frd_overlap = (is_E_use_frs1 & is_M_use_frd & (E_frs1 == M_frd));

//rs2 overlap
assign is_E_rs2_W_rd_overlap = (is_E_use_rs2 & is_W_use_rd & ({{fe[1]},E_rs2} == {{fw[0]},W_rd}) & (W_rd != 5'b0));
assign is_E_rs2_M_rd_overlap = (is_E_use_rs2 & is_M_use_rd & ({{fe[1]},E_rs2} == {{fm[0]},M_rd}) & (M_rd != 5'b0));

// assign is_E_frs2_W_frd_overlap = (is_E_use_frs2 & is_W_use_frd & (E_frs2 == W_frd));
// assign is_E_frs2_M_frd_overlap = (is_E_use_frs2 & is_M_use_frd & (E_frs2 == M_frd));



// alu_op1_sel,alu_op2_sel

assign E_alu_op1_sel = (E_op == `APUIC);
assign E_alu_op2_sel = (E_op == `LD || E_op == `ALUI || E_op == `STYPE || E_op == `BTYPE || E_op == `APUIC || E_op == `FSW || E_op ==`FLW);

//w_WB_DATA_SEL


assign W_wb_data_sel = (W_op == `ALU || W_op == `ALUI || W_op == `JALR || W_op == `JTYPE || W_op == `STYPE || W_op == `APUIC || W_op == `LUI  || W_op == `CSR || W_op == `FAS)?1'b0 : 1'b1;

//DM_wb

assign DM_wb = (M_op == `STYPE || M_op == `FSW)?1'b0 : 1'b1;

//mux 11 12

assign is_D_use_frs1 = (opcode == `FAS);
assign is_D_use_frs2 = (opcode == `FAS || opcode == `FSW);
// assign is_W_use_frd = (W_op == `FLW || W_op == `FAS);
// assign is_M_use_frd = (M_op == `FLW || M_op == `FAS);

assign FD_rs1_data_sel = (is_D_use_frs1 & is_W_use_frd & (dc_rs1 == W_rd) & (W_rd != 5'd0) );
assign FD_rs2_data_sel = (is_D_use_frs2 & is_W_use_frd & (dc_rs2 == W_rd) & (W_rd != 5'd0) );

//stall

assign is_E_load = (E_op == `LD );
assign is_E_fload = (E_op == `FLW);
assign stall = (is_E_load && ((is_D_use_rs1 && (dc_rs1 == E_rd) && (E_rd != 5'b0)) || (is_D_use_rs2 && (dc_rs2 == E_rd) && (E_rd != 5'b0))))||(is_E_fload && ((is_D_use_frs1 && (dc_rs1 == E_rd) ) || (is_D_use_frs2 && (dc_rs2 == E_rd))));


//DM控制

// always @(*) begin
//     if (M_op == `STYPE) begin   
//         if (M_f3 == 3'b010) begin
//             M_dm_w_en = 32'b0;
//         end else if (M_f3 == 3'b000 || M_f3 == 3'b100) begin
//              if (alu_hb_select == 2'd0) begin
//                  M_dm_w_en = {{24{1'b1}},{8{1'b0}}};
//              end else if (alu_hb_select == 2'd1) begin
//                  M_dm_w_en = {{16{1'b1}},{8{1'b0}},{8{1'b1}}};
//              end else if (alu_hb_select == 2'd2) begin
//                  M_dm_w_en = {{8{1'b1}},{8{1'b0}},{16{1'b1}}};
//              end else if (alu_hb_select == 2'd3) begin
//                  M_dm_w_en = {{8{1'b0}},{24{1'b1}}};
//              end
//             //  M_dm_w_en = {{24{1'b1}},{8{1'b0}}};
//         end else if (M_f3 == 3'b001 || M_f3 == 3'b101) begin
//              if (alu_hb_select[1]) begin
//                 M_dm_w_en = {{16{1'b0}},{16{1'b1}}};
//              end else begin
//                 M_dm_w_en = {{16{1'b1}},{16{1'b0}}};
//              end
//         end else begin
//             M_dm_w_en = {{32{1'b1}}};
//         end
//     end else if (M_op == `FSW) begin
//         M_dm_w_en = 32'b0;
//     end
// end
// assign M_dm_w_en = 32'b0;
// assign E_rs1_data_sel = ((is_E_rs1_M_rd_overlap) && (fe == fm))?2'd1 : ((is_E_rs1_W_rd_overlap) && (fe == fw))?2'd0 : (E_op == `FAS )?2'd3 : 2'd2;
// assign E_rs2_data_sel = ((is_E_rs2_M_rd_overlap) && (fe == fm))?2'd1 : ((is_E_rs2_W_rd_overlap) && (fe == fw))?2'd0 : (E_op == `FAS )?2'd3 : 2'd2;

assign E_rs1_data_sel = ((is_E_rs1_M_rd_overlap) )?2'd1 : ((is_E_rs1_W_rd_overlap))?2'd0 : (E_op == `FAS )?2'd3 : 2'd2;
assign E_rs2_data_sel = ((is_E_rs2_M_rd_overlap) )?2'd1 : ((is_E_rs2_W_rd_overlap))?2'd0 : (E_op == `FAS || E_op == `FSW ||E_op == `FLW)?2'd3 : 2'd2;

endmodule