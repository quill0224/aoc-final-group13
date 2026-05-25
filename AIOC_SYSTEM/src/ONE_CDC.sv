module ONE_CDC(
  input clk,  //WRITE
  input rst,
  input clk2, //READ
  input rst2,
  input in,
  output logic out
  );
  
 logic in_f0,in_f1,in_f2;

always_ff @( posedge clk or posedge rst) begin
  if(rst)
    in_f0 <= 1'b0;
  else
    in_f0 <= in;
end
  
always_ff @( posedge clk2 or posedge rst2 ) begin
  if(rst2) begin
    in_f1 <= 1'b0;
    in_f2 <= 1'b0;
  end
  else begin
    in_f1 <= in_f0;
    in_f2 <= in_f1;
  end
end

assign out = in_f2;
  
endmodule
