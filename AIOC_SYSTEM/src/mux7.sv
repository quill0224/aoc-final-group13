module mux7 (
    input [31:0]   rs2_data_reg3,
    input [31:0]   alu_out_reg3,
    input [2:0]     M_f3,

    output logic [3:0]   wstrb,
    output logic [31:0]  rs2_processed_reg3
);

logic [1:0] alu_hb_select;
assign alu_hb_select = alu_out_reg3[1:0];
always @(*) begin
    case(M_f3)
        3'b000:begin
            case (alu_hb_select)
                2'd0:begin
                    rs2_processed_reg3 = {{24{rs2_data_reg3[7]}},{rs2_data_reg3[7:0]}};  
                    wstrb = {{3'b000},{1'b1}}; 
                end
                2'd1:begin
                    rs2_processed_reg3 = {{16{rs2_data_reg3[15]}},{rs2_data_reg3[7:0]},{8{1'b0}}};  
                    wstrb = {{2'b00},{1'b1},{1'b0}}; 
                end
                2'd2:begin
                    rs2_processed_reg3 = {{8{rs2_data_reg3[23]}},{rs2_data_reg3[7:0]},{16{1'b0}}};  
                    wstrb = {{1'b0},{1'b1},{2'b00}}; 
                end
                2'd3:begin
                    rs2_processed_reg3 = {{rs2_data_reg3[7:0]},{24{1'b0}}};
                    wstrb = {{1'b1},{3'b000}}; 
                end       
            endcase
        end
        3'b001:begin
            case (alu_hb_select[1])
                1'b0:begin
                    rs2_processed_reg3 = {{16{rs2_data_reg3[15]}},{rs2_data_reg3[15:0]}};
                    wstrb = {{2'b0},{2'b11}};
                end
                default:begin
                    rs2_processed_reg3 = {{rs2_data_reg3[15:0]},{16{1'b0}}};
                    wstrb = {{2'b11},{2'b00}};
                end
            endcase
        end
        default:begin
            rs2_processed_reg3 = rs2_data_reg3;
            wstrb = 4'b1111;
        end     
    endcase
end 
    
endmodule