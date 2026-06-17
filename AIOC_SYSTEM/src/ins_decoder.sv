module ins_decoder (

    input [31:0] inst,

    output logic reg_web,
    output logic [6:0] opcode,
    output logic       branch_typ,
    output logic [2:0] funct3,
    output logic [4:0] alu_code,
    output logic [4:0] r1_idx,
    output logic [4:0] r2_idx,
    output logic [4:0] rd_idx,
    output logic [31:0] imm,
    output logic       shamt,
    output logic [2:0]   f ,
    output logic [1:0] lui_inst,
    output logic [2:0] compare_inst,
    output logic       orcb,
    output logic [1:0] pack_inst
);

//這邊運用type的運算發送一個訊號去控制mux，來選定進入alu運算的結果//
//new daata那邊的mux 會需要後面的forward補回去，


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

`define BRANCH_NONE 1'b0
`define JB_TYPE 1'b1
`define I_IMM      inst[31:20]//F_IMM相同imm
`define S_IMM      {{20{inst[31]}},{inst[31:25],inst[11:7]}}
`define B_IMM      {{19{inst[31]}},inst[31],inst[7],inst[30:25],inst[11:8],{1'b0}}
`define U_IMM      inst[31:12]
`define J_IMM      {{11{inst[31]}},inst[31],inst[19:12],inst[20],inst[30:21],{1'b0}}
`define IMM_SIGN   inst[31]

//define alu_code = 5'b11111讓alu不做事;

assign r1_idx = `rs1;
assign r2_idx = `rs2;
assign rd_idx = `rd;
assign funct3 = `funct3;
assign opcode = `OPCODE;

always @(*) begin
    case(`OPCODE)
        `ALU: begin
            if (inst[31:25]==7'b0000101) begin//MAX MIN US
                alu_code = 5'd0;
                imm = 32'd0;
                reg_web = 1'b1;
                branch_typ = `BRANCH_NONE;
                shamt = 1'b0;
                f =3'd0;
                lui_inst = 2'd0;
                compare_inst = `funct3;
                orcb = 1'b0;
                pack_inst = 2'd0;
            end else if (inst[31:25] ==7'b0000100) begin//pack
                alu_code = 5'd0;
                imm = 32'd0;
                reg_web = 1'b1;
                branch_typ = `BRANCH_NONE;
                shamt = 1'b0;
                f =3'd0;
                lui_inst = 2'd0;
                compare_inst = 3'd0;
                orcb = 1'b0;
                pack_inst = inst[14:13];//pack 10 packh 11
                
            end else if (inst[25]) begin
                alu_code = {1'b1,1'b1,`funct3};
                imm  = 32'b0;
                reg_web = 1'b1;
                branch_typ = `BRANCH_NONE;
                shamt = 1'b0;
                f = 3'd0;
                lui_inst = 2'd0;
                orcb = 1'b0;
                pack_inst = 2'd0;
                compare_inst = 3'd0;

            end else begin
                alu_code = {1'b0,`funct7_5,`funct3};
                imm = 32'b0;
                reg_web = 1'b1;
                branch_typ = `BRANCH_NONE;
                shamt = 1'b0;
                f = 3'd0;
                lui_inst = 2'd0;
                orcb = 1'b0;
                pack_inst = 2'd0;
                compare_inst = 3'd0;
            end
        end
        `LD: begin
            alu_code = 5'b0;
            imm = {{20{`IMM_SIGN}},`I_IMM};
            reg_web = 1'b1;
            branch_typ = `BRANCH_NONE;
            shamt = 1'b0;
            f = 3'd0;
            lui_inst = 2'd0;
            orcb = 1'b0;
            pack_inst = 2'd0;
            compare_inst = 3'd0;
        end
        `ALUI: begin
            if(inst[29] == 1'b0 && (inst[14:12] == 3'b101 || inst[14:12] == 3'b001)) begin
                alu_code = {1'b0,`funct7_5,`funct3};
                imm      = {27'b0, inst[24:20]};   // shamt, zero-extended
                reg_web  = 1'b1;
                branch_typ = `BRANCH_NONE;
                shamt    = 1'b1;
                f = 3'd0;
                lui_inst = 2'd0;
                orcb = 1'b0;
                pack_inst = 2'd0;
                compare_inst = 3'd0;
            end else if (inst[31:20] == 12'b001010000111 && inst[14:12] == 3'b101) begin//orc.b
                alu_code = 5'd0;
                imm      = {{20{`IMM_SIGN}},`I_IMM}; // sign-extend 12-bit imm
                reg_web  = 1'b1;
                branch_typ = `BRANCH_NONE;
                shamt    = 1'b0;
                f = 3'd0;
                lui_inst = 2'd0;
                orcb = 1'b1;
                pack_inst = 2'd0;
                compare_inst = 3'd0;
            end else if (inst[31:25] == 7'b0110000) begin//sext.b//paclinst == 01
                alu_code = 5'd0;
                imm      = {{20{`IMM_SIGN}},`I_IMM}; // sign-extend 12-bit imm
                reg_web  = 1'b1;
                branch_typ = `BRANCH_NONE;
                shamt    = 1'b0;
                f = 3'd0;
                lui_inst = 2'd0;
                orcb = 1'b0;
                pack_inst = 2'b01;
                compare_inst = 3'd0;
            end else begin
                alu_code = {2'b0,`funct3};
                imm      = {{20{`IMM_SIGN}},`I_IMM}; // sign-extend 12-bit imm
                reg_web  = 1'b1;
                branch_typ = `BRANCH_NONE;
                shamt    = 1'b0;
                f = 3'd0;
                lui_inst = 2'd0;
                orcb = 1'b0;
                pack_inst = 2'd0;
                compare_inst = 3'd0;
            end
        end
        `JALR: begin
            alu_code = 5'b0;
            imm = {{20{`IMM_SIGN}},`I_IMM};
            reg_web = 1'b1;
            branch_typ = `JB_TYPE;
            shamt = 1'b0;
            f = 3'd0;
            lui_inst = 2'd0;
            orcb = 1'b0;
            pack_inst = 2'd0;
            compare_inst = 3'd0;
        end
        `STYPE: begin
            alu_code = 5'b0;
            imm = `S_IMM;
            reg_web = 1'b0;
            branch_typ = `BRANCH_NONE;
            shamt = 1'b0;
            f = 3'd0;
            lui_inst = 2'd0;
            orcb = 1'b0;
            pack_inst = 2'd0;
            compare_inst = 3'd0;
        end
        `BTYPE: begin
            //alu_code = 5'b11111;
            alu_code = 5'b0;
            imm = `B_IMM; 
            reg_web = 1'b0;
            branch_typ = `JB_TYPE;  
            shamt = 1'b0;
            f = 3'd0;
            lui_inst = 2'd0;
            orcb = 1'b0;
            pack_inst = 2'd0;
            compare_inst = 3'd0;
        end
        `APUIC: begin//U-type
            alu_code = 5'b0;
            imm = {`U_IMM,{12{1'b0}}};
            reg_web = 1'b1;
            branch_typ = `BRANCH_NONE;
            shamt = 1'b0;
            f = 3'd0;
            lui_inst = 2'd0;
            orcb = 1'b0;
            pack_inst = 2'd0;
            compare_inst = 3'd0;
        end
        `LUI: begin//U-type
            alu_code =  5'd0;
            imm = {`U_IMM,{12{1'b0}}};
            reg_web = 1'b1;
            branch_typ = `BRANCH_NONE;
            shamt = 1'b0;
            f = 3'd0;
            lui_inst = 2'b01;
            orcb = 1'b0;
            pack_inst = 2'd0;
            compare_inst = 3'd0;
        end
        `JTYPE: begin
            alu_code = 5'b0;
            imm = $signed(`J_IMM);
            reg_web = 1'b1; 
            branch_typ = `JB_TYPE;
            shamt = 1'b0;
            f = 3'd0;
            lui_inst = 2'd0;
            orcb = 1'b0;
            pack_inst = 2'd0;
            compare_inst = 3'd0;
        end
        `FLW:begin
            alu_code = 5'b0;
            branch_typ = `BRANCH_NONE;
            imm = {{20{1'b0}},`I_IMM};
            reg_web = 1'b1; 
            shamt = 1'b0;
            f = 3'b001;//{frs1,frs2,frd}
            lui_inst = 2'd0;
            orcb = 1'b0;
            pack_inst = 2'd0;
            compare_inst = 3'd0;
        end
        `FSW:begin
            alu_code = 5'b0;
            branch_typ = `BRANCH_NONE;
            imm = `S_IMM;
            reg_web = 1'b0; 
            shamt = 1'b0;
            f = 3'b010;//{frs1,frs2,frd}
            lui_inst = 2'd0;
            orcb = 1'b0;
            pack_inst = 2'd0;
            compare_inst = 3'd0;

        end 
        `FAS:begin
            alu_code = {{4'b1110},{inst[27]}};//11100加法,11101減法,用rs2去判斷是否為搬運指令
            branch_typ = `BRANCH_NONE;
            imm =`I_IMM;
            reg_web = 1'b1; 
            shamt = 1'b0;
            f = 3'b111;//{frs1,frs2,frd}
            lui_inst = 2'd0;
            orcb = 1'b0;
            pack_inst = 2'd0;
            compare_inst = 3'd0;
        end
        `CSR:begin
            alu_code = 5'd0;//
            branch_typ = `BRANCH_NONE;
            imm = {{20{1'b0}},`I_IMM};
            reg_web = 1'b1; 
            shamt = 1'b0;
            f = 3'd0;//{frs1,frs2,frd}
            lui_inst = 2'd0;
            orcb = 1'b0;
            pack_inst = 2'd0;
            compare_inst = 3'd0;
        end
        default:begin
            alu_code = 5'd0;//
            branch_typ = `BRANCH_NONE;
            imm = {{20{1'b0}},`I_IMM};
            reg_web = 1'b0; 
            shamt = 1'b0;
            f = 3'd0;//{frs1,frs2,frd}
            lui_inst = 2'd0;
            orcb = 1'b0;
            pack_inst = 2'd0;
            compare_inst = 3'd0;
        end
    endcase
end



endmodule