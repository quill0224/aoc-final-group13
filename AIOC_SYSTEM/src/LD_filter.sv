module LD_filter (
    input   [31:0]  ld_data,
    input   [2:0]   W_f3,
    input   [31:0]  alu_out_reg4,
    output logic [31:0] LD_out
);

logic [1:0] select;
logic ld_data_7,ld_data_15,ld_data_23,ld_data_31;
assign ld_data_7 = ld_data[7];
assign ld_data_15 = ld_data[15];
assign ld_data_23 = ld_data[23];
assign ld_data_31 = ld_data[31];
assign select = alu_out_reg4[1:0];
always @(*) begin
    case (W_f3)
        3'b010: begin//LW
            LD_out = ld_data; 
        end
        3'b000: begin//LB
            LD_out = (select==2'b00)? {{24{ld_data_7}},ld_data[7:0]} :
                     (select==2'b01)? {{24{ld_data_15}}, ld_data[15:8]} :
                     (select==2'b10)? {{24{ld_data_23}}, ld_data[23:16]} :
                     {{24{ld_data[31]}}, ld_data[31:24]};            
            // {{24{ld_data_7}},ld_data[7:0]};
        end 
        3'b001: begin//LH
            LD_out =(select==2'b00)? {{16{ld_data[15]}}, ld_data[15:0]} :
                    (select==2'b01)? {{16{ld_data[23]}}, ld_data[23:8]} :
                    (select==2'b10)? {{16{ld_data[31]}}, ld_data[31:16]} :
                    {{16{ld_data[15]}}, ld_data[15:0]};
        end
        3'b100: begin//LBU
            LD_out = (select==2'b00)? {{24'd0},ld_data[7:0]} :
                     (select==2'b01)? {{24'd0}, ld_data[15:8]} :
                     (select==2'b10)? {{24'd0}, ld_data[23:16]} :
                     {{24'd0}, ld_data[31:24]};
        end
        3'b101: begin//LHU
            LD_out =(select==2'b00)? {{16'd0},ld_data[15:0]} :
                    (select==2'b01)? {16'b0, ld_data[23:8]} :
                    (select==2'b10)? {16'b0, ld_data[31:16]} :
                    {{16'd0},ld_data[23:8]};
        end  
        default:LD_out = 32'd0 ;
    endcase
end    
endmodule


//  module LD_filter (
//     input   [31:0]  ld_data,
//     input   [2:0]   W_f3,
//     input   [31:0]  alu_out_reg4,
//     output logic [31:0] LD_out
// );

// logic [1:0] select;
// logic ld_data_7,ld_data_15,ld_data_23,ld_data_31;
// assign ld_data_7 =  ld_data[7];
// assign ld_data_15 = ld_data[15];
// assign ld_data_23 = ld_data[23];
// assign ld_data_31 = ld_data[31];
// assign select = alu_out_reg4[1:0];
// always @(*) begin
//     case (W_f3)
//         3'b010: begin//LW
//             LD_out = ld_data; 
//         end
//         3'b000: begin//LB
//             LD_out = (select==2'b00)? {{24{ld_data[7]}},ld_data[7:0]}          :
//                      (select==2'b01)? {{16{ld_data[15]}},ld_data[15:8],8'b0}   :
//                      (select==2'b10)? {{8{ld_data[23]}},ld_data[23:16],16'b0}  :
//                      {ld_data[31:24],24'b0};
//         end 
//         3'b001: begin//LH
//             LD_out = (select==2'b00)? {{16{ld_data[15]}}, ld_data[15:0]}  :
//                      (select==2'b01)? {{16{ld_data[15]}}, ld_data[15:0]}  :
//                      (select==2'b10)? { ld_data[31:16],16'b0} :
//                      { ld_data[31:16],16'b0};
//         end
//         3'b100: begin//LBU
//             LD_out = (select==2'b00)? {24'b0,ld_data[7:0]}          :
//                      (select==2'b01)? {16'b0,ld_data[15:8],8'b0}    :
//                      (select==2'b10)? {8'b0,ld_data[23:16],16'b0}   :
//                      {ld_data[31:24],24'b0};
//         end
//         3'b101: begin//LHU
//             LD_out = (select==2'b00)? {16'd0, ld_data[15:0]}  :
//                      (select==2'b01)? {16'd0, ld_data[15:0]}  :
//                      (select==2'b10)? {ld_data[31:16],16'd0} :
//                      {ld_data[31:16],16'd0};
//         end  
//         default:LD_out = 32'd0 ;
//     endcase
// end    
// endmodule