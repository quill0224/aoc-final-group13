module reg_file (

    input [4:0]  r1_idx,
    input [4:0]  r2_idx, 
    input [31:0] write_back,
    input        W_wb_en,
    input [4:0]  W_rd_idx,
    input clk,rst,

    output logic [31:0] rs1_data,
    output logic [31:0] rs2_data

);

reg [31:0] reg_file [31:0];


assign rs1_data = (r1_idx == 5'd0) ? 32'b0 : reg_file[r1_idx];
assign rs2_data = (r2_idx == 5'd0) ? 32'b0 : reg_file[r2_idx];


integer i;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        for (i = 0; i < 32; i = i + 1) begin
        reg_file[i] <= 32'b0;
        end 
        end else begin
            if (W_wb_en && (W_rd_idx[4:0] != 5'd0)) begin
                reg_file[W_rd_idx[4:0]] <= write_back;
            end else begin
                reg_file[W_rd_idx[4:0]] <= reg_file[W_rd_idx[4:0]];
            end
    end
end

endmodule