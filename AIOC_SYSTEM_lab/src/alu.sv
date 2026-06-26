module alu (
    input  [31:0]    s1,
    input  [31:0]    s2,
    input  [4:0]     alu_code,
    input [31:0] imm,
    input 			 shamt,//確保ALUI運算是吃到shamt_code
    input  			 branch_typ,
		input  [1:0] lui_inst,
		input  [2:0] compare_inst,
		input				 orcb,
		input	 [1:0] pack_inst,
		input  [2:0] fe,		

    output logic [31:0]   alu_result
);

`define shamt_code imm[4:0]//定義shamt_code的平移量

logic [63:0] mux_result ;
logic [7:0]  exp1,exp2,index1,index2,count;
logic [24:0] fraction1,fraction2;
logic [24:0] fraction;
logic [31:0] op1,op2;
logic [31:0] ALUout;

always_comb begin
    ALUout = 32'd0;
    op1 = s1;
    op2 = s2;
    exp1 = op1[30:23];
    exp2 = op2[30:23];
    fraction1 = {2'b01,op1[22:0]};
    fraction2 = {2'b01,op2[22:0]};
    index1 = exp1-exp2-8'd1;
    index2 = exp2-exp1-8'd1;
    	if((alu_code[0] == 1'b0 && op1[31] == op2[31]) || (alu_code[0] == 1'b1 && op1[31] != op2[31])) begin//加法
		if(exp1 > exp2)begin
			fraction2 = fraction2 >>(exp1 - exp2);
			fraction = fraction1 + fraction2;
			
			if(fraction2[index1[4:0]])//the Round to Nearest, ties to Evenmode. 
				fraction = fraction + 25'd1;
			else 
				fraction = fraction - 25'd1;	
				
			if(fraction[24])begin
				exp1 = exp1 + 8'd1;
				ALUout = {op1[31],exp1,fraction[23:1]};
			end
			else
				ALUout = {op1[31],exp1,fraction[22:0]};
		end
		else if(exp1 < exp2)begin
			fraction1 = fraction1 >> (exp2 - exp1);
			fraction = fraction1 + fraction2;
			
			if(fraction1[index2[4:0]])//the Round to Nearest, ties to Evenmode. 
				fraction = fraction + 25'd1;
			else 
				fraction = fraction - 25'd1;
			
			if(fraction[24])begin
				exp1 = exp1 + 8'd1;
				ALUout = {op1[31],exp1,fraction[23:1]};
			end
			else
				ALUout = {op1[31],exp1,fraction[22:0]};
		end
		else begin//exp1 = exp2
			fraction = fraction1 + fraction2;
			exp1 = exp1 + 8'd1;
			ALUout = {op1[31],exp1,fraction[23:1]};
		end
	end	
	else begin//減法
		if(exp1 > exp2)begin
			fraction2 = fraction2 >>(exp1 - exp2);
			fraction = fraction1 - fraction2;
			
			if(fraction2[index1[4:0]])//the Round to Nearest, ties to Evenmode. 
				fraction = fraction - 25'd1;
			else 
				fraction = fraction + 25'd1;
			
			if(~fraction[23])begin
				exp1 = exp1 - 8'd1;
				ALUout = {op1[31],exp1,fraction[21:0],1'b0};
			end
			else 
				ALUout = {op1[31],exp1,fraction[22:0]};
		end
		else if(exp1 < exp2)begin
			fraction1 = fraction1 >> (exp2 - exp1);
			fraction = fraction1 - fraction2;
			
			if(fraction1[index2[4:0]])//the Round to Nearest, ties to Evenmode. 
				fraction = fraction - 25'd1;
			else 
				fraction = fraction + 25'd1;
			
			if(~fraction[23])begin
				exp2 = exp2 - 8'd1;
				ALUout = {op2[31],exp2,fraction[21:0],1'b0};
			end
			else
				ALUout = {op2[31],exp1,fraction[22:0]};
		end
		else begin //exp1 = exp2
			if(fraction1 > fraction2)begin
				fraction = fraction1 - fraction2;
				casex(fraction[23:0])
					24'b01xxxxxxxxxxxxxxxxxxxxxx:count=8'd1;
					24'b001xxxxxxxxxxxxxxxxxxxxx:count=8'd2;
					24'b0001xxxxxxxxxxxxxxxxxxxx:count=8'd3;
					24'b00001xxxxxxxxxxxxxxxxxxx:count=8'd4;
					24'b000001xxxxxxxxxxxxxxxxxx:count=8'd5;
					24'b0000001xxxxxxxxxxxxxxxxx:count=8'd6;
					24'b00000001xxxxxxxxxxxxxxxx:count=8'd7;
					24'b000000001xxxxxxxxxxxxxxx:count=8'd8;
					24'b0000000001xxxxxxxxxxxxxx:count=8'd9;
					24'b00000000001xxxxxxxxxxxxx:count=8'd10;
					24'b000000000001xxxxxxxxxxxx:count=8'd11;
					24'b0000000000001xxxxxxxxxxx:count=8'd12;
					24'b00000000000001xxxxxxxxxx:count=8'd13;
					24'b000000000000001xxxxxxxxx:count=8'd14;
					24'b0000000000000001xxxxxxxx:count=8'd15;
					24'b00000000000000001xxxxxxx:count=8'd16;
					24'b000000000000000001xxxxxx:count=8'd17;
					24'b0000000000000000001xxxxx:count=8'd18;
					24'b00000000000000000001xxxx:count=8'd19;
					24'b000000000000000000001xxx:count=8'd20;
					24'b0000000000000000000001xx:count=8'd21;
					24'b00000000000000000000001x:count=8'd22;
					24'b000000000000000000000001:count=8'd23;
					24'b000000000000000000000000:count=8'd24;
					default:count=8'd0;
				endcase
				fraction = fraction << count;
				exp1 = exp1 - count;
				ALUout = {(~op2[31]), exp1, fraction[22:0]};
			end
			if (fraction1 < fraction2) begin
				fraction = fraction2 - fraction1;
				casex(fraction[23:0])
					24'b01xxxxxxxxxxxxxxxxxxxxxx:count=8'd1;
					24'b001xxxxxxxxxxxxxxxxxxxxx:count=8'd2;
					24'b0001xxxxxxxxxxxxxxxxxxxx:count=8'd3;
					24'b00001xxxxxxxxxxxxxxxxxxx:count=8'd4;
					24'b000001xxxxxxxxxxxxxxxxxx:count=8'd5;
					24'b0000001xxxxxxxxxxxxxxxxx:count=8'd6;
					24'b00000001xxxxxxxxxxxxxxxx:count=8'd7;
					24'b000000001xxxxxxxxxxxxxxx:count=8'd8;
					24'b0000000001xxxxxxxxxxxxxx:count=8'd9;
					24'b00000000001xxxxxxxxxxxxx:count=8'd10;
					24'b000000000001xxxxxxxxxxxx:count=8'd11;
					24'b0000000000001xxxxxxxxxxx:count=8'd12;
					24'b00000000000001xxxxxxxxxx:count=8'd13;
					24'b000000000000001xxxxxxxxx:count=8'd14;
					24'b0000000000000001xxxxxxxx:count=8'd15;
					24'b00000000000000001xxxxxxx:count=8'd16;
					24'b000000000000000001xxxxxx:count=8'd17;
					24'b0000000000000000001xxxxx:count=8'd18;
					24'b00000000000000000001xxxx:count=8'd19;
					24'b000000000000000000001xxx:count=8'd20;
					24'b0000000000000000000001xx:count=8'd21;
					24'b00000000000000000000001x:count=8'd22;
					24'b000000000000000000000001:count=8'd23;
					24'b000000000000000000000000:count=8'd24;
					default:count=8'd0;
				endcase
				fraction = fraction << count;
				exp2 = exp2 - count;
				ALUout = {(~op1[31]), exp2, fraction[22:0]};
			end
		end
	end
end		


// logic [31:0] s2_m;
// logic s1_s,s2_s,ss_s;
// logic [7:0] s1_e,s2_e,ss_e;
// logic [22:0] s1_f,s2_f,ss_f;
// logic [25:0] s2_f_sh;
// logic [25:0] s1_f_ext,s2_f_ext;
// logic [25:0] s1_f_com,s2_f_com;
// logic [25:0] fs_f_com;
// logic [25:0] fs_f_cal;
// logic [4:0] fs_shift_num;
// logic [7:0] ex_diff;
// logic [22:0] round_manti;
// logic valid,zero ;
// assign s2_m = {alu_code[0]^s2[31],s2[30:0]};
// assign s1_s = (s1[30:23] > s2[30:23])?s1[31]:s2_m[31] ;
// assign s1_e = (s1[30:23] > s2[30:23])?s1[30:23]:s2_m[30:23] ;
// assign s1_f = (s1[30:23] > s2[30:23])?s1[22:0]:s2_m[22:0] ;
// assign s2_s = (s1[30:23] > s2[30:23])?s2_m[31]:s1[31];
// assign s2_e = (s1[30:23] > s2[30:23])?s2_m[30:23]:s1[30:23];
// assign s2_f = (s1[30:23] > s2[30:23])?s2_m[22:0]:s1[22:0];

// assign s1_f_ext = (s1[30:23]==0) ? {3'b000, s1_f} : {3'b001, s1_f};
// assign s2_f_ext = (s2[30:23]==0) ? {3'b000, s2_f} : {3'b001, s2_f};

// assign ex_diff = s1_e - s2_e;
// assign s2_f_sh = s2_f_ext >> ex_diff;

// assign s1_f_com = (s1_s)? ~s1_f_ext + 26'd1 : s1_f_ext;
// assign s2_f_com = (s2_s)? ~s2_f_sh  + 26'd1 : s2_f_sh;

// assign fs_f_cal = s1_f_com + s2_f_com;
// assign fs_f_com = (fs_f_cal[25])? ~fs_f_cal +26'd1 : fs_f_cal;

// assign ss_s = fs_f_cal[25];
// assign ss_e = (fs_f_com[24])?s1_e + 8'd1 : s1_e - (5'd23 - fs_shift_num);
// assign ss_f = (fs_f_com[24])?fs_f_com[23:1] : fs_f_com[22:0] << (5'd23 - fs_shift_num);

// assign zero = !(valid | fs_f_com[24] | fs_f_com[25]);
// assign round_manti = (ss_f[23:0] > 24'h800000) ? (ss_f + 32'h01000000) : ((ss_f[23:0] ==  24'h800000) & ss_f[24]) ? (ss_f + 32'h01000000):ss_f;


// logic [31:0] first_pos;
// logic [31:0] mant_sum;
// logic [5:0] idx;
// assign mant_sum = {8'd0,fs_f_com[23:0]};
// integer i;
// assign first_pos = mant_sum & (~(mant_sum-1));
// always_comb begin
//     idx = 1'd0;
//     for (i=0 ; i<32 ; i=i+1) begin
//         if (first_pos[i]) begin
//             idx = i;
//         end
//     end
// end
// assign fs_shift_num = idx;



                                              
//alu
always_comb begin
		if (lui_inst == 2'b01) begin//LUI
			mux_result = 64'd0;
			alu_result = imm;
		end else if (compare_inst != 3'd0) begin
			mux_result = 64'd0;
			case (compare_inst)
				3'b110:begin//MAX
					alu_result = (($signed(s1))<($signed(s2)))?s2:s1;
				end 
				3'b111:begin
					alu_result = (($unsigned(s1))<($unsigned(s2)))?s2:s1;
				end
				3'b100:begin
					alu_result = (($signed(s1))<($signed(s2)))?s1:s2;
				end
				3'b101:begin
					alu_result = (($unsigned(s1))<($unsigned(s2)))?s1:s2;
				end
				default:alu_result= 32'd0; 
			endcase
		end 
		else if (orcb)		    begin
			mux_result = 32'd0;
            alu_result[31:24] = (s1[31:24] != 8'd0) ? 8'hFF : 8'h00;
            alu_result[23:16] = (s1[23:16] != 8'd0) ? 8'hFF : 8'h00;
            alu_result[15:8]  = (s1[15:8]  != 8'd0) ? 8'hFF : 8'h00;
            alu_result[7:0]   = (s1[7:0]   != 8'd0) ? 8'hFF : 8'h00;
		end 
		else if (pack_inst != 2'd0)begin
			mux_result = 32'd0;
			alu_result = (pack_inst == 2'b10) ? {s2[15:0], s1[15:0]} :
                         (pack_inst == 2'b11) ? {16'd0, s2[7:0], s1[7:0]} : 
                         (pack_inst == 2'b01) ? {{24{s1[7]}}, s1[7:0]} : 32'd0;
		end 
		else begin
        case (alu_code)
            5'b00000: begin
                mux_result = 64'd0;
                alu_result = $signed(s1) + $signed(s2);
            end
            5'b00001: begin
                if (shamt == 1'b1) begin
                    mux_result = 64'd0;
                    alu_result = s1 <<< `shamt_code;
                end else begin
                mux_result = 64'd0;
                alu_result = s1 << s2[4:0];
                end
            end
            5'b00010: begin
                mux_result = 64'b0;
                alu_result = ($signed(s1) < $signed(s2))?1:0;
            end
            5'b00011: begin
                mux_result = 64'b0;
                alu_result = (s1 < s2)?1:0;
            end
            5'b00100: begin
                mux_result = 64'b0;
                alu_result = s1 ^ s2;
            end
            5'b00101: begin
                if (shamt) begin
                    mux_result = 64'b0;
                    alu_result = s1 >>> `shamt_code;
                end else begin
                mux_result = 64'b0;
                alu_result = s1 >> s2[4:0]; 
                end  
            end
            5'b00110: begin
                mux_result = 64'b0;
                alu_result = s1 | s2;
            end
            5'b00111: begin
                mux_result = 64'b0;
                alu_result = s1 & s2;
            end
            5'b01000: begin
                mux_result = 64'b0;
                alu_result = $signed(s1) - $signed(s2);
            end
						5'b01100: begin//XNOR
								mux_result = 64'd0;
								alu_result = (~s1) ^ (s2);
						end
            5'b01101: begin
                if (shamt) begin
                    mux_result = 64'b0;
                    alu_result = $signed(s1) >>> `shamt_code;
                end else begin
                mux_result = 64'b0;
                alu_result = $signed(s1) >> s2[4:0];
                end 		
            end
						5'b01110: begin//ORN
								mux_result = 64'd0;
								alu_result = s1 | (~s2);
						end
						5'b01111: begin//ANDN
								mux_result = 64'd0;
								alu_result = s1 & (~s2);
						end
            5'b11000: begin
                mux_result = ($unsigned({{32{1'b0}}, s1})*$unsigned({{32{1'b0}}, s2}));
                alu_result = mux_result[31:0];
            end
            5'b11001: begin
                mux_result = ($signed({{32{s1[31]}}, s1})*$signed({{32{s2[31]}}, s2}));
                alu_result = mux_result[63:32];
            end
            5'b11010: begin
                mux_result = ($signed({{32{s1[31]}}, s1})*$unsigned({{32{1'b0}}, s2}));
                alu_result = mux_result[63:32];
            end
            5'b11011: begin//MULHU
                mux_result = ($unsigned({{32{1'b0}}, s1})*$unsigned({{32{1'b0}}, s2}));
                alu_result = mux_result[63:32];
            end
            5'b11100: begin//FADD(111)//DIV
                if (fe == 3'b111) begin
                    mux_result = 64'd0;
                    alu_result = ALUout; // Floating point case
                end 
				else if (s2 == 32'd0) begin
                    mux_result = 64'd0;
                    alu_result = 32'hFFFFFFFF; // RISC-V spec: div by 0 returns -1
                end 
				else if (s1 == 32'h80000000 && s2 == 32'hFFFFFFFF) begin
                    mux_result = 64'd0;
                    alu_result = 32'h80000000; // RISC-V spec: signed overflow
                end 
				else begin
                    mux_result = 64'd0;
                    alu_result = $signed(s1) / $signed(s2);
                end
            end
            5'b11101: begin//FSUB(111)//DIVU
                if (fe == 3'b111) begin
                    mux_result = 64'd0;
                    alu_result = ALUout; 
                end else if (s2 == 32'd0) begin
                    mux_result = 64'd0;
                    alu_result = 32'hFFFFFFFF; // RISC-V spec: div by 0 returns MAX value
                end else begin
                    mux_result = 64'd0;
                    alu_result = $unsigned(s1) / $unsigned(s2);
                end
            end
			5'b11110: begin // REM
                if (s2 == 32'd0) begin
                    // 1. 除以 0 保護
                    mux_result = 64'd0;
                    alu_result = s1; // RISC-V 規定餘數除以 0 回傳被除數
                end else if (s1 == 32'h80000000 && s2 == 32'hFFFFFFFF) begin
                    // 2. Signed Overflow 保護
                    mux_result = 64'd0;
                    alu_result = 32'd0; 
                end else begin
                    mux_result = 64'd0;
                    alu_result = $signed(s1) % $signed(s2);
                end
            end
			5'b11111: begin // REMU
                if (s2 == 32'd0) begin
                    // 1. 除以 0 保護
                    mux_result = 64'd0;
                    alu_result = s1; 
                end else begin
                    mux_result = 64'd0;
                    alu_result = ($unsigned(s1)) % ($unsigned(s2));
                end
            end
            default:  begin
                mux_result = 64'd0;
                alu_result = 32'd0;
            end
        endcase
		end
end 



endmodule