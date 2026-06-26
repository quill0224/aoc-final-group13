module reg_f_file (

    input [4:0]  r1_idx,
    input [4:0]  r2_idx, 
    input [31:0] f_write_back,
    input        f_W_wb_en,
    input [4:0]  f_W_rd_idx,
    input clk,rst,

    output logic [31:0] frs1_data,
    output logic [31:0] frs2_data

);


reg [31:0] f_reg_file [31:0];



assign frs1_data = (r1_idx == 5'd0) ? 32'b0 : f_reg_file[r1_idx];
assign frs2_data = (r2_idx == 5'd0) ? 32'b0 : f_reg_file[r2_idx];

integer i;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        for (i = 0; i < 32; i = i + 1) begin
        f_reg_file[i] <= 32'b0;
        end 
        end else begin
            if (f_W_wb_en && (f_W_rd_idx[4:0] != 5'd0)) begin
                f_reg_file[f_W_rd_idx[4:0]] <= f_write_back;
            end else begin
                f_reg_file[f_W_rd_idx[4:0]] <= f_reg_file[f_W_rd_idx[4:0]];
            end
    end
end

endmodule