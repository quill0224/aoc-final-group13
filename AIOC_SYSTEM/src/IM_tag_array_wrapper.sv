module IM_tag_array_wrapper (
  input CK,RST,
  input WEB,
  input [4:0] A,
  input [22:0] DI,
  input victim_way,
  input renew,
  input OE,
  //output
  output [22:0] DO1,
  output [22:0] DO2,
  output logic valid1,valid2

);
logic [31:0] valid_reg1,valid_reg2,BWEB1,BWEB2;
logic [31:0] Q1,Q2;

assign DO1 = (valid1 && OE)?Q1[22:0]:23'd0;
assign DO2 = (valid2 && OE)?Q2[22:0]:23'd0;

assign valid1 = valid_reg1[A];
assign valid2 = valid_reg2[A];

always @(posedge CK or posedge RST) begin
  if (RST) begin
    valid_reg1 <= 32'd0;
    valid_reg2 <= 32'd0;
  end else begin
    valid_reg1[A] <= (renew && victim_way == 1'b0)?1'b1:valid_reg1[A];
    valid_reg2[A] <= (renew && victim_way == 1'b1)?1'b1:valid_reg2[A];
  end
  
end

assign WEB1 = (victim_way==1'b0 && renew && ~WEB) ?1'b0:1'b1;
assign WEB2 = (victim_way==1'b1 && renew && ~WEB) ?1'b0:1'b1;

assign BWEB1 = (victim_way==1'b0 && renew && ~WEB) ?32'b0:32'hFFFFFFFF;
assign BWEB2 = (victim_way==1'b1 && renew && ~WEB) ?32'b0:32'hFFFFFFFF;

  TS1N16ADFPCLLLVTA128X64M4SWSHOD_tag_array i_tag_array1 (
    .CLK        (CK),
    .A          (A),
    .CEB        (1'b0),  // chip enable, active LOW
    .WEB        (WEB1),  // write:LOW, read:HIGH
    .BWEB       (BWEB1),  // bitwise write enable write:LOW
    .D          ({9'd0,DI}),  // Data into RAM
    .Q          (Q1),  // Data out of RAM
    .RTSEL      (2'b01),
    .WTSEL      (2'b01),
    .SLP        (1'b0),
    .DSLP       (1'b0),
    .SD         (1'b0),
    .PUDELAY    ()
  );

  TS1N16ADFPCLLLVTA128X64M4SWSHOD_tag_array i_tag_array2 (
    .CLK        (CK),
    .A          (A),
    .CEB        (1'b0),  // chip enable, active LOW
    .WEB        (WEB2),  // write:LOW, read:HIGH
    .BWEB       (BWEB2),  // bitwise write enable write:LOW
    .D          ({9'd0,DI}),  // Data into RAM
    .Q          (Q2),  // Data out of RAM
    .RTSEL      (2'b01),
    .WTSEL      (2'b01),
    .SLP        (1'b0),
    .DSLP       (1'b0),
    .SD         (1'b0),
    .PUDELAY    ()
  );

endmodule
