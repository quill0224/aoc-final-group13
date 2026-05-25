module easy_decoder(
    input [31:0] inst,//IM_DO
    input [31:0] pc ,

    output logic [31:0] address_pre,
    output logic  B_type

);
`define opcode      inst[6:0]
`define B_IMM      {{19{inst[31]}},inst[31],inst[7],inst[30:25],inst[11:8],{1'b0}}
logic [31:0] imm;
assign imm = `B_IMM;
always_comb begin 
    if (`opcode == 7'b1100011) begin//Bytpe
        address_pre = (imm + pc);
        B_type = 1'b1;
    end else begin
        address_pre = 32'd0;
        B_type = 1'b0;
    end
end
endmodule
