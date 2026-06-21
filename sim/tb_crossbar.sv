// Throwaway: verify crossbar gather (iverilog; crossbar has no mfiu)
`timescale 1ns/1ps
module tb_crossbar;
  import trapezoid_pkg::*;

  logic valid; logic [LANE_COUNT_W-1:0] effectual;
  logic [N_MUL_ROW-1:0][3:0] a_meta; logic [N_MUL_ROW-1:0][5:0] b_meta;
  logic [3:0] grp_base;
  logic [15:0][7:0] a_nz_row; logic [15:0][7:0] b_nz [0:15];
  logic [7:0] a_val [0:15]; logic [7:0] b_val [0:15];
  logic [3:0] lane_col [0:15]; logic lane_valid [0:15]; logic valid_out;

  crossbar dut(.valid(valid),.effectual(effectual),.a_meta(a_meta),.b_meta(b_meta),.grp_base(grp_base),
    .a_nz_row(a_nz_row),.b_nz(b_nz),.a_val(a_val),.b_val(b_val),.lane_col(lane_col),
    .lane_valid(lane_valid),.valid_out(valid_out));

  integer i,c,k,fails; logic [127:0] atmp,btmp;

  task chk(input integer l,input [7:0] ea,input [7:0] eb,input [3:0] ec,input ev,input string nm);
    if(a_val[l]!==ea || b_val[l]!==eb || (ev && lane_col[l]!==ec) || lane_valid[l]!==ev) begin
      $display("[FAIL] %s lane%0d a=%h b=%h col=%0d v=%b (exp a=%h b=%h col=%0d v=%b)",
        nm,l,a_val[l],b_val[l],lane_col[l],lane_valid[l],ea,eb,ec,ev); fails=fails+1;
    end
  endtask

  initial begin
    fails=0;
    atmp=0; for(k=0;k<16;k=k+1) atmp[k*8+:8]=8'(8'hA0+k); a_nz_row=atmp;          // a_nz_row[i]=0xA0+i
    for(c=0;c<16;c=c+1) begin btmp=0; for(k=0;k<16;k=k+1) btmp[k*8+:8]=8'((c<<4)|k); b_nz[c]=btmp; end // b_nz[c][k]=(c<<4)|k

    // ===== Test1: group0 (grp_base=0),= tb_mfiu basic 的 meta =====
    valid=1; effectual=4; grp_base=0; a_meta='0; b_meta='0;
    a_meta[0]=4'd0; a_meta[1]=4'd2; a_meta[2]=4'd1; a_meta[3]=4'd2;
    b_meta[0]=6'h00; b_meta[1]=6'h01; b_meta[2]=6'h10; b_meta[3]=6'h11;
    #1;
    chk(0,8'hA0,8'h00,4'd0,1'b1,"T1");
    chk(1,8'hA2,8'h01,4'd0,1'b1,"T1");
    chk(2,8'hA1,8'h10,4'd1,1'b1,"T1");
    chk(3,8'hA2,8'h11,4'd1,1'b1,"T1");
    chk(4, 8'h00,8'h00,4'd0,1'b0,"T1");
    chk(15,8'h00,8'h00,4'd0,1'b0,"T1");
    if(fails==0) $display("[PASS] T1: group0 gather (grp_base=0) a/b/col 全對");

    // ===== Test2: grp_base offset(驗真實欄 = grp_base + group內欄)=====
    valid=1; effectual=1; grp_base=4; a_meta='0; b_meta='0;
    a_meta[0]=4'd3; b_meta[0]=6'h25;   // col_in_grp=2, idx=5 → 真實欄=4+2=6
    #1;
    chk(0,8'hA3,8'h65,4'd6,1'b1,"T2");
    chk(1,8'h00,8'h00,4'd0,1'b0,"T2");
    if(fails==0) $display("[PASS] T2: grp_base offset 真實欄=6 gather 正確");

    $display("");
    if(fails==0) $display("==== TB PASS ===="); else $display("==== TB FAIL (%0d) ====",fails);
    $finish;
  end
endmodule
