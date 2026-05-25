module  CSR (
    input clk,
    input rst,
    input jb,stall,
    input [31:0] imm,rs1_data,
    input [31:0] pc,
    input [4:0] E_rd,E_rs1,
    input [6:0] E_op,
    input [2:0] E_f3,
    input DMA_Interrupt,WDT_Interrupt,
    output logic [31:0] CSR_out,
    output logic [31:0] CSR_pc,
    output logic Interrupt_take,Interrupt_return,
    output logic WFI_take_reg
);


logic [31:0] mstatus,mie,mepc,mip;

logic [63:0] instret,cycle;
logic [31:0] x,csr;
logic Interrupt_enable_DMA,Interrupt_take_WDT,Interrupt_enable;
logic Interrupt_take_DMA;
logic WFI_reg,WFI_take;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        instret <= 64'd0;
        cycle <= 64'd0;
    end else begin
        cycle <= cycle + 64'd1;
        if (pc == 0) begin
            instret <= instret;
        end else begin
            instret <= instret + 64'd1;
        end
    end
end


always @(posedge clk or posedge rst) begin
    if(rst)begin
        mstatus        <= 32'd0;
    end else if (Interrupt_take) begin
        mstatus[12] <= 1'b1; 
        mstatus[11] <= 1'b1;    //MPP <= 2’b11(machine mode)
        mstatus[7]     <= mstatus[3];//MPIE <= MIE
        mstatus[3]     <= 1'b0;      //MIE <= 0
    end else if (Interrupt_return) begin
        mstatus[12:11] <= 2'b11;
        mstatus[7] <= 1'b1;
			  mstatus[3] <= mstatus[7];		  
    end else if (E_op == 7'b1110011 && imm[11:0] == 12'h300) begin
        case (E_f3)
              3'b001:begin
                mstatus[3] <= rs1_data[3];
                mstatus[7] <= rs1_data[7];
                mstatus[12:11] <= rs1_data[12:11]; 
              end
              3'b010:begin
                mstatus[3] <= (E_rs1 != 5'b00000)? rs1_data[3]  : mstatus[3]; 
                mstatus[7] <= (E_rs1 != 5'b00000)? rs1_data[7]  : mstatus[7];
                mstatus[12:11] <= (E_rs1 != 5'b00000)? rs1_data[12:11]  : mstatus[12:11];
              end 
              3'b011:begin
                mstatus <= (E_rs1 != 5'b00000)? mstatus&(~rs1_data) : mstatus;
              end
              3'b101:begin
                mstatus[3] <= E_rs1[3];
              end
              3'b110:begin
                mstatus[3] <= (E_rs1[4:0]!=5'b00000)? mstatus[3]|imm[3]    : mstatus[3];
              end
              3'b111:begin
                mstatus[3] <= (E_rs1[4:0]!=5'b00000)? mstatus[3]&(~E_rs1[3]) : mstatus[3];
              end
            default:mstatus <= mstatus;
        endcase
    end   
end

//mip
always @(posedge clk or posedge rst) begin
    if(rst)begin
        mip            <= 32'd0;
    end else if (Interrupt_take_DMA) begin
        mip[11]        <= 1'b1;
        mip[7]         <= 1'b0;
    end else if (Interrupt_take_WDT) begin
        mip[11] <= 1'b0;
        mip[7]         <= 1'b1;
    end else if (E_op == 7'b1110011 && imm[11:0] == 12'h344) begin
        case (E_f3)
              3'b001:begin
                mip <= mip;        
              end
              3'b010:begin
                mip <= (E_rs1 != 5'b00000)? mip|rs1_data    : 32'd0;  
              end 
              3'b011:begin
                mip <= (E_rs1 != 5'b00000)? mip&(~rs1_data) : 32'd0;
              end
              3'b101:begin
                mip[11] <= 1'b0 ;
                mip[7]  <= 1'b0 ;
              end
              3'b110:begin
                mip <= (imm[4:0]!=5'b00000)? mip|imm    : 32'd0;
              end
              3'b111:begin
                mip <= (imm[4:0]!=5'b00000)? mip&(~imm) : 32'd0;
              end
            default:mip <= mip;
        endcase
    end  
end

//mie
always @(posedge clk or posedge rst) begin
    if(rst)begin
        mie            <= 32'd0;
    end else if (E_op == 7'b1110011 && imm[11:0] == 12'h304) begin
        case (E_f3)
              3'b001:begin
                mie[11] <= rs1_data[11];   
                mie[7] <= rs1_data[7];  
              end
              3'b010:begin
                mie <= (E_rs1 != 5'b00000)? mie|rs1_data    : 32'd0;  
              end 
              3'b011:begin
                mie <= (E_rs1 != 5'b00000)? mie&(~rs1_data) : 32'd0;
              end
              3'b101:begin
                mie <= imm;
              end
              3'b110:begin
                mie <= (imm[4:0]!=5'b00000)? mie|imm    : 32'd0;
              end
              3'b111:begin
                mie <= (imm[4:0]!=5'b00000)? mie&(~imm) : 32'd0;
              end
            default:mie <= mie;
        endcase        
    end
end     

//mepc
always @(posedge clk or posedge rst) begin
    if (rst) begin
        mepc <= 32'd0;   
    end else if (Interrupt_take_WDT) begin
        mepc <= pc; 
    end else if (WFI_take) begin
        mepc <= pc + 32'd4;
    end else if (E_op == 7'b1110011 && imm[11:0] == 12'h341)begin
        case (E_f3)
              3'b001:begin
                mepc <= rs1_data;     
              end
              3'b010:begin
                mepc <= (E_rs1 != 5'b00000)? mepc|rs1_data    : 32'd0;  
              end 
              3'b011:begin
                mepc <= (E_rs1 != 5'b00000)? mepc&(~rs1_data) : 32'd0;
              end
              3'b101:begin
                mepc <= (E_rs1[4:0]!=5'b00000)? {27'd0,E_rs1}         : mepc;
              end
              3'b110:begin
                mepc <= (E_rs1[4:0]!=5'b00000)? mepc|{27'd0,E_rs1}    : 32'd0;
              end
              3'b111:begin
                mepc <= (imm[4:0]!=5'b00000)? mepc&(~imm) : 32'd0;
              end
            default:mepc <= mepc;
        endcase 
    end
end

always_comb begin 
    case (imm[11:0])
        12'b110010000010:begin
            CSR_out = instret[63:32];
        end
        12'b110000000010:begin
            CSR_out = instret[31:0] + 32'd1;
        end
        12'b110010000000:begin
            CSR_out = cycle[63:32];
        end
        12'b110000000000:begin
            CSR_out = cycle[31:0];
        end
        12'h300:begin//mstatus
            CSR_out =(E_rd != 5'b00000)?mstatus:32'd0;
        end
        12'h304:begin//mie
            CSR_out =(E_rd != 5'b00000)?mie:32'd0;
        end
        12'h305:begin//mtvec
            CSR_out =(E_rd != 5'b00000)?32'h00010000:32'd0;
        end
        12'h341:begin//mepc
            CSR_out =(E_rd != 5'b00000)?mepc:32'd0;
        end
        12'h344:begin//mip
            CSR_out =(E_rd != 5'b00000)?mip:32'd0;
        end
        default: CSR_out = 32'd0 ;
    endcase 
end

assign CSR_pc =(Interrupt_take)? 32'h00010000 : (E_f3 == 3'b00 && imm[11:0] == 12'h302) ? mepc:32'd0;
assign Interrupt_enable = mstatus[3];//////////gobal interrupt enable
assign Interrupt_enable_DMA = mie[11];/////////MEIE
assign Interrupt_enable_WDT = mie[7];/////////MTIE

assign Interrupt_take_DMA = (DMA_Interrupt && Interrupt_enable_DMA /*&& (WFI_take || Interrupt_enable)*/) ? 1'b1 : 1'b0;
assign Interrupt_take_WDT = (WDT_Interrupt && Interrupt_enable_WDT /*&& (WFI_take || Interrupt_enable)*/) ? 1'b1 : 1'b0;
assign Interrupt_take = (Interrupt_take_DMA || Interrupt_take_WDT) ? 1'b1 : 1'b0;
assign Interrupt_return = (E_f3 == 3'b000 && imm[11:0] == 12'h302) ? 1'b1 : 1'b0;


//WFI

always @(posedge clk  or posedge rst) begin
  if (rst) begin
    WFI_reg <= 1'd0;
  end else if(Interrupt_take)begin
    WFI_reg <= 1'b0;
  end else if(E_f3 == 3'd0 && imm[11:0] == 12'h105)begin
    WFI_reg <= 1'd1;
  end else begin
    WFI_reg <= WFI_reg;
  end
end
assign WFI_take_reg = (E_f3 == 3'd0 && imm[11:0] == 12'h105)? 1'b1 : WFI_reg;
assign WFI_take     = (E_f3 == 3'd0 && imm[11:0] == 12'h105);
endmodule