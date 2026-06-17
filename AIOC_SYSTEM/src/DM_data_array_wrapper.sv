module DM_data_array_wrapper (
  input CK,RST,
  input CS, 
  input [15:0] BWEB,
  input [4:0] A,
  input [127:0] DI,
  input [1:0] hit_select,
  input victim_way,
  input WEB,
  input s_hit_renew,L_NO_HIT_renew,
  output [127:0] DO
);
logic [63:0] data_array1_1_out,data_array1_2_out,data_array2_1_out,data_array2_2_out;
logic [127:0] BWEB1,BWEB2;
logic [1:0]hit_select_reg;
assign DO = (hit_select == 2'b01)?{{data_array1_2_out},{data_array1_1_out}}:
            (hit_select == 2'b10)?{{data_array2_2_out},{data_array2_1_out}}:
            128'd0;
assign WEB1 = (s_hit_renew && hit_select_reg == 2'b01)?1'b0:(victim_way==1'b0 && ~WEB && L_NO_HIT_renew) ?1'b0:1'b1;
assign WEB2 = (s_hit_renew && hit_select_reg == 2'b10)?1'b0:(victim_way==1'b1 && ~WEB && L_NO_HIT_renew) ?1'b0:1'b1;

assign BWEB1 = (s_hit_renew && hit_select_reg == 2'b01)?{{8{BWEB[15]}},{8{BWEB[14]}},{8{BWEB[13]}},{8{BWEB[12]}},{8{BWEB[11]}},{8{BWEB[10]}},{8{BWEB[9]}},{8{BWEB[8]}},{8{BWEB[7]}},{8{BWEB[6]}},{8{BWEB[5]}},{8{BWEB[4]}},{8{BWEB[3]}},{8{BWEB[2]}},{8{BWEB[1]}},{8{BWEB[0]}}}:(victim_way==1'b0)?{{8{BWEB[15]}},{8{BWEB[14]}},{8{BWEB[13]}},{8{BWEB[12]}},{8{BWEB[11]}},{8{BWEB[10]}},{8{BWEB[9]}},{8{BWEB[8]}},{8{BWEB[7]}},{8{BWEB[6]}},{8{BWEB[5]}},{8{BWEB[4]}},{8{BWEB[3]}},{8{BWEB[2]}},{8{BWEB[1]}},{8{BWEB[0]}}}:{128{1'b1}};
assign BWEB2 = (s_hit_renew && hit_select_reg == 2'b10)?{{8{BWEB[15]}},{8{BWEB[14]}},{8{BWEB[13]}},{8{BWEB[12]}},{8{BWEB[11]}},{8{BWEB[10]}},{8{BWEB[9]}},{8{BWEB[8]}},{8{BWEB[7]}},{8{BWEB[6]}},{8{BWEB[5]}},{8{BWEB[4]}},{8{BWEB[3]}},{8{BWEB[2]}},{8{BWEB[1]}},{8{BWEB[0]}}}:(victim_way==1'b1)?{{8{BWEB[15]}},{8{BWEB[14]}},{8{BWEB[13]}},{8{BWEB[12]}},{8{BWEB[11]}},{8{BWEB[10]}},{8{BWEB[9]}},{8{BWEB[8]}},{8{BWEB[7]}},{8{BWEB[6]}},{8{BWEB[5]}},{8{BWEB[4]}},{8{BWEB[3]}},{8{BWEB[2]}},{8{BWEB[1]}},{8{BWEB[0]}}}:{128{1'b1}};

always @(posedge CK or posedge RST) begin
  if (RST) begin
    hit_select_reg <= 2'd0;
  end else if (s_hit_renew) begin
    hit_select_reg <= 2'd0;
  end else if (hit_select != 2'd0) begin
    hit_select_reg <= hit_select;
  end else
    hit_select_reg <= hit_select_reg;
end

  TS1N16ADFPCLLLVTA128X64M4SWSHOD_data_array i_data_array1_1 (
    .CLK        (CK),
    .A          (A),
    .CEB        (1'b0),  // chip enable, active LOW
    .WEB        (WEB1),  // write:LOW, read:HIGH
    .BWEB       (BWEB1[63:0]),  // bitwise write enable write:LOW
    .D          (DI[63:0]),  // Data into RAM
    .Q          (data_array1_1_out),  // Data out of RAM
    .RTSEL      (2'b01),
    .WTSEL      (2'b01),
    .SLP        (1'b0),
    .DSLP       (1'b0),
    .SD         (1'b0),
    .PUDELAY    ()
  );
  
  
    TS1N16ADFPCLLLVTA128X64M4SWSHOD_data_array i_data_array1_2 (
    .CLK        (CK),
    .A          (A),
    .CEB        (1'b0),  // chip enable, active LOW
    .WEB        (WEB1),  // write:LOW, read:HIGH
    .BWEB       (BWEB1[127:64]),  // bitwise write enable write:LOW
    .D          (DI[127:64]),  // Data into RAM
    .Q          (data_array1_2_out),  // Data out of RAM
    .RTSEL      (2'b01),
    .WTSEL      (2'b01),
    .SLP        (1'b0),
    .DSLP       (1'b0),
    .SD         (1'b0),
    .PUDELAY    ()
  );

  TS1N16ADFPCLLLVTA128X64M4SWSHOD_data_array i_data_array2_1 (
    .CLK        (CK),
    .A          (A),
    .CEB        (1'b0),  // chip enable, active LOW
    .WEB        (WEB2),  // write:LOW, read:HIGH
    .BWEB       (BWEB2[63:0]),  // bitwise write enable write:LOW
    .D          (DI[63:0]),  // Data into RAM
    .Q          (data_array2_1_out),  // Data out of RAM
    .RTSEL      (2'b01),
    .WTSEL      (2'b01),
    .SLP        (1'b0),
    .DSLP       (1'b0),
    .SD         (1'b0),
    .PUDELAY    ()
  );
  
  TS1N16ADFPCLLLVTA128X64M4SWSHOD_data_array i_data_array2_2 (
    .CLK        (CK),
    .A          (A),
    .CEB        (1'b0),  // chip enable, active LOW
    .WEB        (WEB2),  // write:LOW, read:HIGH
    .BWEB       (BWEB2[127:64]),  // bitwise write enable write:LOW
    .D          (DI[127:64]),  // Data into RAM
    .Q          (data_array2_2_out),  // Data out of RAM
    .RTSEL      (2'b01),
    .WTSEL      (2'b01),
    .SLP        (1'b0),
    .DSLP       (1'b0),
    .SD         (1'b0),
    .PUDELAY    ()
  );


endmodule
