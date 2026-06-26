module mux_jb(
  input jb_save,
  input [31:0] PC_out,reg_jb_pc,
  output logic [31:0] PC_IM
);
assign PC_IM = (jb_save)?reg_jb_pc:PC_out;
endmodule