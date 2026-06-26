`define ADDRESS_SIZE 14
`define DATA_WIDH 32
`define REG_NUM 32

`define OPCODE      inst[6:0]
`define rs1         inst[19:15]
`define rs2         inst[24:20]
`define rd          inst[11:7]
`define funct7_5    inst[30]
`define funct3      inst[14:12]


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
`define FAS         7'b1010011
`define CSR         7'b1110011


module CPU (
    input logic clk,
    input logic rst,
    input [31:0] DM_do,
    input [31:0] IM_do,
    input stop_IM , stop_DM,//等到HS資料傳遞
    input DMA_Interrupt,WTO,//新增
    output logic [31:0] pc_out,
    output logic [31:0] DM_addr,
    output logic [31:0] DM_data,
    output logic [1:0] DM_inst_type,
    output logic [1:0] DM_inst,
    output logic [3:0] DM_WSTRB,
    // output logic [31:0] M_dm_w_en,
    output logic    WFI_take_reg


);
logic        DM_wb,jb_save;
logic [31:0] PC_out;
logic [31:0] PC1_out;
logic        stall;//連接stall訊號
logic        jb;//連接jb跳躍訊號控制reg
logic        IM_eb;
logic [31:0] PC_for_IM;

logic [31:0] inst;
//decoder
logic [6:0]  opcode_decoder_out;
logic        branch_typ;
logic [2:0]  funct3_decoder_out;
logic [4:0]  alu_code_decoder_out;
logic [4:0]  r1_idx,r2_idx,rd_idx;
logic [31:0] imm;
logic        shamt,shamt_ex;//控制shamt的alu
logic        reg_web;//隨著訊號一起往後傳，最後控制W_wb_en
//reg_file
logic [31:0] write_back;
logic [31:0] rs1_data;
logic [31:0] rs2_data;
logic        W_wb_en,f_W_wb_en,W_wb_en_reg_file;
logic [4:0]  W_rd_idx;
//mux1,2   
logic  D_rs1_data_sel,D_rs2_data_sel; 
logic [31:0] mux1_out,mux2_out;     
//reg 2
logic [31:0] PC2_out,imm2_out,rs1_data2,rs2_data2;
logic        reg_web_out2,branch_typ2;
//CSR
logic [31:0] CSR_out,CSR_pc;
//mux3,4
logic [31:0] alu_out_write_back,mux3_out,mux4_out;
logic [1:0]  E_rs1_data_sel,E_rs2_data_sel;
//mux5,6
logic [31:0] mux5_out,mux6_out;
logic E_alu_op1_sel,E_alu_op2_sel;
//alu
logic [31:0] alu_result;
logic [4:0]  E_alu_code;
//E_op,f3,rd,rs1,rs2
logic [6:0]  E_op;
logic [2:0]  E_f3;
logic [4:0]  E_rd;//多一位表f or not f
logic [4:0]  E_rs1,E_rs2;//多一位表f or not f
//JB_out
logic [31:0] JB_pc,jb_rd_out;
logic branch_result;//控制branch_predictor的FSM
logic [1:0] state;

//reg3
logic [31:0] PC3_out,rs2_out_reg3;
logic reg_web_out3;

//reg4
logic [31:0] alu_out_reg4,Id_data_out,DM_do_reg4;
//M_op,f3,rd
logic [6:0] M_op;
logic [2:0] M_f3;
logic [4:0] M_rd;
//W_op,f3,rd
logic [6:0] W_op;
logic [2:0] W_f3;
logic [4:0] W_rd;
//LD_filter
logic [31:0] LD_out;
//mux8 
logic W_wb_data_sel;
//mux9
logic [31:0] mux9_out;
logic   d_rst;
//branch_predictor
logic [31:0] address_pre;
logic address_sl;
logic B_type;
//控制f相關訊號
logic falu_code_reg2,falu_code;
logic [31:0] frs1_data,frs1_out,frs2_data,frs2_out;
logic FD_rs1_data_sel,FD_rs2_data_sel,frs1,frs2,frd;
logic [31:0] mux11_out,mux12_out;
logic [2:0] f,fe,fm,fw;//f = {frs1,frs2,frd};
//
logic [31:0] mux_ad_out,reg_jb;

logic [31:0] DM_addr_reg;//存柱DMADDR地址和DM_inst指令
logic [31:0] DM_data_reg;

logic [1:0]  DM_inst_reg;
logic [3:0]  wstrb_reg,wstrb;

logic [31:0] rs2_processed_reg3;
// logic [1:0] DM_inst;
logic [31:0] alu_out_reg3;
logic Interrupt_return,Interrupt_take;

//new inst
logic [1:0] lui_inst_ID,lui_inst_EX,pack_inst_ID,pack_inst_EX;
logic [2:0] compare_inst_ID,compare_inst_EX;
logic orcb_ID,orcb_EX;

assign pc_out = (PC_out == 32'h00010000)?PC_out:
                (CSR_pc != 32'd0)?CSR_pc:    
                (jb_save)?reg_jb:PC_out;
assign W_wb_en_reg_file = (W_op == `ALU || W_op == `LD || W_op == `ALUI || W_op == `JALR || W_op == `APUIC || W_op == `LUI || W_op == `JTYPE || W_op == `CSR );


always @(posedge clk or posedge rst)begin
    if(rst)
        d_rst <= 1'b0;
    else 
        d_rst <= 1'b1;  
end
//IF開始
mux0 mux0(
    .jb_pc(JB_pc),
    .pc_cycle(pc_out),
    .branch_result(branch_result),
    .jb(jb),
    .stall(stall),
    .d_rst_bar(~d_rst),
    .mux0_out(PC_for_IM)
);

mux_ad mux_ad(
    //input
    .address_pre(address_pre),
    .address_ori(PC_for_IM),
    .address_sl (address_sl),
    //output
    .mux_ad_out(mux_ad_out)
);

PC_reg PC(
    .clk(clk),
    .rst(rst),
    .in(mux_ad_out),
    .stall(stall),
    .stop_DM(stop_DM),
    .stop_IM(stop_IM),
    .branch_typ(branch_typ),
    .branch_typ2(branch_typ2),
    .WFI_take_reg(WFI_take_reg),
    .Interrupt_return(Interrupt_return),
    .Interrupt_take(Interrupt_take),
    .CSR_pc(CSR_pc),
    //output
    .pc_reg_out(PC_out)
);
// mux_jb mux_jb(
//     .jb_save(jb_save),
//     .PC_out(PC_out),
//     .reg_jb_pc(reg_jb),
//     .PC_IM(PC_IM)//真正傳給IM的地址
// );

reg_jb_pc reg_jb_pc(
    .clk(clk),
    .rst(rst),
    .jb(jb),
    .stop_IM(stop_IM),
    .mux_ad_out(mux_ad_out),
    .reg_jb_pc(reg_jb),
    .jb_save(jb_save)
);

//branch predictor起
easy_decoder easy_decoder(
    //input
    .inst(IM_do),
    .pc(pc_out),
    //output
    .address_pre(address_pre),
    .B_type(B_type)
);


branch_predictor branch_predictor(
    //input
    .clk(clk),
    .rst(rst),
    .branch_result(branch_result),
    .E_op(E_op),
    .B_type(B_type),
    .jb(jb),
    //output
    .address_sl(address_sl),
    .state(state)
);
//branch predictor終
//IF結束

reg1 reg1(
    //input
    .clk(clk),
    .rst(~d_rst),
    .stall(stall),
    .stop_DM(stop_DM),
    .stop_IM(stop_IM),
    .IM_do(IM_do),
    .jb(jb),
    .pc1(pc_out),
    .Interrupt_take(Interrupt_take),
    .WFI_take_reg(WFI_take_reg),
    //output
    .pc1_out(PC1_out),
    .inst(inst)
);

//ID開始
ins_decoder decoder (
    //input
    .inst(inst),
    //output
    .opcode(opcode_decoder_out),
    .branch_typ(branch_typ),
    .funct3(funct3_decoder_out),
    .alu_code(alu_code_decoder_out),
    .r1_idx(r1_idx),
    .r2_idx(r2_idx),
    .rd_idx(rd_idx),
    .imm(imm),
    .shamt(shamt),
    .reg_web(reg_web),
    .f(f),
    .lui_inst(lui_inst_ID),
    .compare_inst(compare_inst_ID),
    .orcb(orcb_ID),
    .pack_inst(pack_inst_ID)
);

reg_file reg_file(
    .clk(clk),
    .rst(rst),
    .r1_idx(r1_idx),
    .r2_idx(r2_idx),
    .write_back(write_back),
    .W_wb_en(W_wb_en_reg_file),
    .W_rd_idx(W_rd_idx),
    .rs1_data(rs1_data),
    .rs2_data(rs2_data)
);

reg_f_file reg_f_file(
    .r1_idx(r1_idx),
    .r2_idx(r2_idx),
    .f_write_back(write_back),
    .f_W_wb_en(f_W_wb_en),
    .f_W_rd_idx(W_rd_idx),
    .clk(clk),
    .rst(rst),
    //output
    .frs1_data(frs1_data),
    .frs2_data(frs2_data)
);


mux1 mux1(
    .mux1_i1(rs1_data),
    .mux1_i2(write_back),
    .D_rs1_data_sel(D_rs1_data_sel),
    .mux1_out(mux1_out)
);

mux2 mux2(
    .mux2_i1(rs2_data),
    .mux2_i2(write_back),
    .D_rs2_data_sel(D_rs2_data_sel),
    .mux2_out(mux2_out)
);
mux11 mux11(
    .mux11_i0(frs1_data),
    .mux11_i1(write_back),
    .FD_rs1_data_sel(FD_rs1_data_sel),
    .mux11_out(mux11_out)
);
mux12 mux12(
    .mux12_i0(frs2_data),
    .mux12_i1(write_back),
    .FD_rs2_data_sel(FD_rs2_data_sel),
    .mux12_out(mux12_out)
);

//ID結束

reg2 reg2(
    .clk(clk),
    .rst(rst),
    .jb(jb_save),
    .stall(stall),
    .stop_DM(stop_DM),
    .reg_web(reg_web),
    .branch_typ(branch_typ),
    .imm2(imm),
    .opcode(opcode_decoder_out),
    .funct3(funct3_decoder_out),
    .rd_idx(rd_idx),
    .alu_code(alu_code_decoder_out),
    .r1_idx(r1_idx),
    .r2_idx(r2_idx),
    .frs1_data(mux11_out),
    .frs2_data(mux12_out),
    .f(f),
    .Interrupt_take(Interrupt_take),
    .WFI_take_reg(WFI_take_reg),
    .lui_inst_ID(lui_inst_ID),
    .pack_inst_ID(pack_inst_ID),
    .compare_inst_ID(compare_inst_ID),
    .orcb_ID(orcb_ID),
    //output
    .pc2(PC1_out),
    .rs1(mux1_out),
    .rs2(mux2_out),
    .pc2_out(PC2_out),
    .imm_out(imm2_out),
    .rs1_out(rs1_data2),
    .rs2_out(rs2_data2),
    .frs1_out(frs1_out),
    .frs2_out(frs2_out),
    .reg_web_out(reg_web_out2),
    .branch_typ2(branch_typ2),
    .E_op(E_op),
    .E_f3(E_f3),
    .E_rd(E_rd),
    .E_alu_code(E_alu_code),
    .E_rs1(E_rs1),
    .E_rs2(E_rs2),
    .shamt(shamt),
    .shamt_ex(shamt_ex),
    .fe(fe),
    .lui_inst_EX(lui_inst_EX),
    .compare_inst_EX(compare_inst_EX),
    .orcb_EX(orcb_EX),
    .pack_inst_EX(pack_inst_EX)

);

//EX開始


CSR CSR(
    //input
    .clk(clk),
    .rst(rst),
    .jb(jb),
    .stall(stall),
    .imm(imm2_out),
    .rs1_data(mux3_out),
    .pc(PC2_out),
    .E_rd(E_rd),
    .E_rs1(E_rs1),
    .E_op(E_op),
    .E_f3(E_f3),
    .DMA_Interrupt(DMA_Interrupt),
    .WDT_Interrupt(WTO),
    //output
    .CSR_out(CSR_out),
    .CSR_pc(CSR_pc),
    .Interrupt_take(Interrupt_take),
    .Interrupt_return(Interrupt_return),
    .WFI_take_reg(WFI_take_reg)
);
mux3 mux3(
    .mux3_i0(write_back),
    .mux3_i1(alu_out_reg3),
    .mux3_i2(rs1_data2),
    .mux3_i3(frs1_out),
    .E_rs1_data_sel(E_rs1_data_sel),
    .mux3_out(mux3_out)
);
mux4 mux4(
    .mux4_i0(write_back),
    .mux4_i1(alu_out_reg3),
    .mux4_i2(rs2_data2),
    .mux4_i3(frs2_out),
    .E_rs2_data_sel(E_rs2_data_sel),
    .mux4_out(mux4_out)    
);
mux5 mux5(
    .mux5_i0(mux3_out),
    .mux5_i1(PC2_out),
    .E_alu_op1_sel(E_alu_op1_sel),
    .mux5_out(mux5_out)
);
mux6 mux6(
    .mux6_i0(mux4_out),
    .mux6_i1(imm2_out),
    .E_alu_op2_sel(E_alu_op2_sel),
    .mux6_out(mux6_out)
);

alu alu(
    .s1(mux5_out),
    .s2(mux6_out),
    .branch_typ(branch_typ2),
    .imm(imm2_out),
    .alu_code(E_alu_code),
    .shamt(shamt_ex),
    .fe(fe),
    .lui_inst(lui_inst_EX),
    .compare_inst(compare_inst_EX),
    .orcb(orcb_EX),
    .pack_inst(pack_inst_EX),
    .alu_result(alu_result)
);
JB_Unit JB_Unit(
    //input
    .opcode(E_op),
    .funct3(E_f3),
    .pc(PC2_out),
    .imm(imm2_out),
    .rs1(mux3_out),
    .rs2(mux4_out),
    .branch_typ(branch_typ2),
    .state(state),
    //output
    .rd_out(jb_rd_out),
    .JB_out(JB_pc),
    .jb(jb),  
    .branch_result(branch_result)  
);
mux9 mux9(
    .alu_jb_sel(branch_typ2),
    .alu_out(alu_result),
    .opcode(E_op),
    .jb_out(jb_rd_out),
    .CSR_out(CSR_out),
    .mux9_out(mux9_out)
);
//EX結束


reg3 reg3(
    .clk(clk),
    .rst(rst),
    .E_op(E_op),
    .E_f3(E_f3),
    .E_rd(E_rd),
    .pc2(PC2_out),
    .alu_result(mux9_out),
    .rs2_data(mux4_out),
    .fe(fe),
    .stop_DM(stop_DM),
    //output
    .reg_web(reg_web_out2),
    .alu_out(alu_out_reg3),
    .rs2_out(rs2_out_reg3),
    .reg_web_out(reg_web_out3),
    .M_op(M_op),
    .M_f3(M_f3),
    .M_rd(M_rd),
    .pc3(PC3_out),
    .fm(fm)
);

//MEM開始

mux7 mux7(
    //input
    .rs2_data_reg3(rs2_out_reg3),
    .alu_out_reg3(alu_out_reg3),
    .M_f3(M_f3),
    //output
    .rs2_processed_reg3(rs2_processed_reg3),
    .wstrb(wstrb)
);
//鎖住丟出去給DM的值
always @(posedge clk or posedge rst) begin
    if (rst) begin
        DM_addr_reg <= 32'd0;
        DM_inst_reg <= 2'd0;
        wstrb_reg <= 4'd0;
        DM_data_reg <= 32'd0;
    end else if (M_op == 7'b0100011 || M_op == 7'b0100111 || M_op == 7'b0000011 || M_op == 7'b0000111) begin
        DM_addr_reg <= alu_out_reg3;
        DM_inst_reg <= DM_inst;
        wstrb_reg <= wstrb;
        DM_data_reg <= rs2_processed_reg3;
    end else if (~stop_DM) begin
        DM_addr_reg <= 32'd0;
        DM_inst_reg <= 2'd0;
        wstrb_reg <= 4'd0;
        DM_data_reg <= 32'd0;
    end else begin
        DM_addr_reg <= DM_addr_reg;
        DM_inst_reg <= DM_inst_reg;
        wstrb_reg <= wstrb_reg;
        DM_data_reg <= DM_data_reg;
    end 
end

//output port端
assign DM_addr = DM_addr_reg;
assign DM_inst_type = (PC3_out==32'd0)?2'd0:DM_inst_reg;
assign DM_WSTRB = wstrb_reg;
assign DM_data = DM_data_reg;
assign DM_inst = (M_op == 7'b0100011 || M_op == 7'b0100111 )?2'b11:(M_op == 7'b0000011 || M_op == 7'b0000111)?2'b10:2'b01;
//
//MEM結束

reg4 reg4(
    //input
    .clk(clk),
    .rst(rst),
    .alu_out_in(alu_out_reg3),
    .M_op(M_op),
    .M_rd(M_rd),
    .M_f3(M_f3),
    .fm(fm),
    .stop_DM(stop_DM),
    .DM_do(DM_do),
    //output
    .pc3(PC3_out),
    .reg_web(reg_web_out3),
    .alu_out_out(alu_out_reg4),
    .reg_web_out(W_wb_en),
    .W_op(W_op),
    .W_rd(W_rd_idx),
    .W_f3(W_f3),
    .fw(fw),
    .DM_do_reg4(DM_do_reg4),
    .pc4()
);


//WB開始
LD_filter LD_filter(
    .ld_data(DM_do_reg4),
    .W_f3(W_f3),
    .alu_out_reg4(alu_out_reg4),
    .LD_out(LD_out)
);

mux8 mux8(  
    .s1(alu_out_reg4),
    .LD_out(LD_out),
    .W_wb_data_sel(W_wb_data_sel),
    .mux8_out(write_back)
);
//WB結束


Forward Forward(
    //input
    .clk(clk),
    .rst(rst),
    .opcode(opcode_decoder_out),
    .E_op(E_op),
    .M_op(M_op),
    .M_f3(M_f3),
    .W_op(W_op),
    .E_rd(E_rd),
    .M_rd(M_rd),
    .W_rd(W_rd_idx),
    .dc_rs1(r1_idx),
    .dc_rs2(r2_idx),
    .E_rs1(E_rs1),
    .E_rs2(E_rs2),
    .alu_out_reg3(alu_out_reg3),
    .FD_rs1_data_sel(FD_rs1_data_sel),
    .FD_rs2_data_sel(FD_rs2_data_sel),
    .fd(f),
    .fe(fe),
    .fm(fm),
    .fw(fw),
    //output
    .E_rs1_data_sel(E_rs1_data_sel),
    .E_rs2_data_sel(E_rs2_data_sel),
    .D_rs1_data_sel(D_rs1_data_sel),
    .D_rs2_data_sel(D_rs2_data_sel),
    .E_alu_op1_sel(E_alu_op1_sel),
    .E_alu_op2_sel(E_alu_op2_sel),
    // .M_dm_w_en(M_dm_w_en),
    .W_wb_data_sel(W_wb_data_sel),
    .stall(stall),
    .DM_wb(DM_wb),
    .f_W_wb_en(f_W_wb_en)

);

// reg_f_file reg_f_file(
//     .r1_idx(r1_idx),
//     .r2_idx(r2_idx),
//     .f_write_back(write_back),
//     .f_W_wb_en(f_W_wb_en),
//     .f_W_rd_idx(W_rd_idx),
//     .clk(clk),
//     .rst(rst),
//     //output
//     .frs1_data(frs1_data),
//     .frs2_data(frs2_data)
// );


endmodule