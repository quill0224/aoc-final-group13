module JB_Unit (

    input    [6:0]  opcode,
    input    [2:0]  funct3,
    input    [31:0] pc,
    input    [31:0] imm,
    input    [31:0] rs1,
    input    [31:0] rs2,
    input           branch_typ,
    input    [1:0]  state,

    output logic  [31:0] JB_out,
    output logic  [31:0] rd_out,
    output logic         jb,branch_result
);



`define strongly_not_taken 2'd1
`define weakly_not_taken   2'd0
`define weakly_taken       2'd2
`define strongly_taken     2'd3

always @(*) begin
    if (branch_typ == 1'b1) begin
        case (opcode)
            7'b1100011: begin//BTYPE
                case (funct3)
                    3'b000: begin
                        JB_out = (rs1 == rs2)? pc+imm : pc + 4;  
                        branch_result = (rs1 == rs2)? 1'b1 : 1'b0; 
                        rd_out = 32'b0; 
                        if (state == `strongly_not_taken || state == `weakly_not_taken) begin
                            jb = (branch_result);
                        end  else if (state == `strongly_taken || state == `weakly_taken) begin
                            jb = (!branch_result);
                        end else begin
                            jb = 1'd0;
                        end            
                    end 
                    3'b001: begin
                        JB_out = (rs1 != rs2)? pc+imm : pc + 4;
                        branch_result = (rs1 != rs2)? 1'b1 : 1'b0; 
                        rd_out = 32'b0;
                        if (state == `strongly_not_taken || state == `weakly_not_taken) begin
                            jb = (branch_result);
                        end  else if (state == `strongly_taken || state == `weakly_taken) begin
                            jb = (!branch_result);
                        end else begin
                            jb = 1'd0;
                        end      
                    end
                    3'b100: begin
                        JB_out = ($signed(rs1) < $signed(rs2))? pc + $signed(imm) : pc + 4;
                        branch_result = ($signed(rs1) < $signed(rs2))? 1'b1 : 1'b0; 
                        rd_out = 32'b0;
                        if (state == `strongly_not_taken || state == `weakly_not_taken) begin
                            jb = (branch_result);
                        end  else if (state == `strongly_taken || state == `weakly_taken) begin
                            jb = (!branch_result);
                        end else begin
                            jb = 1'd0;
                        end  
                    end
                    3'b101: begin
                        JB_out = ($signed(rs1) >= $signed(rs2))? pc + $signed(imm) : pc + 4;
                        branch_result = ($signed(rs1) >= $signed(rs2))? 1'b1 : 1'b0; 
                        rd_out = 32'b0;
                        if (state == `strongly_not_taken || state == `weakly_not_taken) begin
                            jb = (branch_result);
                        end  else if (state == `strongly_taken || state == `weakly_taken) begin
                            jb = (!branch_result);
                        end else begin
                            jb = 1'd0;
                        end      
                    end
                    3'b110: begin
                        JB_out = ($unsigned(rs1) <  $unsigned(rs2))? pc + $signed(imm) :  pc + 4;
                        branch_result = ($unsigned(rs1) < $unsigned(rs2))? 1'b1 : 1'b0; 
                        rd_out = 32'b0; 

                        if (state == `strongly_not_taken || state == `weakly_not_taken) begin
                            jb = (branch_result);
                        end  else if (state == `strongly_taken || state == `weakly_taken) begin
                            jb = (!branch_result);
                        end else begin
                            jb = 1'd0;
                        end      
                    end  
                    3'b111: begin
                        JB_out = ($unsigned(rs1) >= $unsigned(rs2))? pc + $signed(imm) :  pc + 4;
                        branch_result = ($unsigned(rs1) >= $unsigned(rs2))? 1'b1 : 1'b0; 
                        rd_out = 32'b0; 
                        // jb = 1;
                        if (state == `strongly_not_taken || state == `weakly_not_taken) begin
                            jb = (branch_result);
                        end  else if (state == `strongly_taken || state == `weakly_taken) begin
                            jb = (!branch_result);
                        end else begin
                            jb = 1'd0;
                        end     
                    end              
                    default:begin
                        JB_out = 32'b0;
                        branch_result = 1'b0;
                        rd_out = 32'b0;

                        if (state == `strongly_not_taken || state == `weakly_not_taken) begin
                            jb = (branch_result);
                        end  else if (state == `strongly_taken || state == `weakly_taken) begin
                            jb = (!branch_result);
                        end else begin
                            jb = 1'd0;
                        end      
                    end 
                endcase
            end
            7'b1101111: begin//JAL
                JB_out = pc + $signed(imm);
                branch_result = 1'b0;
                jb = 1'd1;
                rd_out = pc + 32'd4;   
            end 
            7'b1100111:begin//JALR
                JB_out = $signed(imm) + rs1;
                branch_result = 1'b0;
                jb = 1'd1;
                rd_out = pc + 32'd4;
                
            end
            default:begin
                JB_out = 32'b0;
                branch_result = 1'b0;
                rd_out = 32'b0;
                jb = 1'd0;
            end
        endcase 
    end else begin
        JB_out = 32'b0;
        branch_result = 1'b0;
        rd_out = 32'b0;
        jb = 1'd0;
    end
end
endmodule