module reg_jb_pc(
  input jb,clk,rst,
  input stop_IM,
  input [31:0] mux_ad_out,
  output logic [31:0] reg_jb_pc,
  output logic jb_save
);  

always @(posedge clk or posedge rst) begin
  if (rst) begin
    reg_jb_pc <= 32'd0;
    jb_save <= 1'd0;
  end else if(jb && stop_IM) begin
    reg_jb_pc <= mux_ad_out;
    jb_save <= jb;
  end else if (~stop_IM) begin
    reg_jb_pc <=32'd0;
    jb_save <= 1'd0;
  end else begin
    reg_jb_pc <= reg_jb_pc;
    jb_save <= jb_save;
  end
end


endmodule