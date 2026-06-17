module IM_cache (
  input clk,rst,
  input [31:0]            core_addr,
  // input                   core_write,
  // input [31:0]            core_in,
  // input [2:0]             core_type,
  input [127:0]           I_out,
  input                   I_wait,
  input                   WFI_take_reg,
  output logic [31:0]     core_out,
  output logic            core_wait,
  output logic            I_req,
  output logic [31:0]     I_addr
  // output logic            I_write,
  // output logic [31:0]     I_in,
  // output logic [2:0]      I_type,
  
);  
`define Tag            core_addr[31:9]
`define set_index      core_addr[8:4]
// `define block_offset   core_addr[3:2]
`define byte_offset    core_addr[1:0]

logic valid1,valid2;
logic [4:0]  index;
logic TA_write,TA_read,DA_read;
logic [22:0] TA_in,TA_out1,TA_out2;
logic [15:0] DA_write;
logic [127:0] DA_in,DA_out,data;
logic hit1,hit2;
logic [1:0]hit_select;
// logic [127:0]data1,data2;
logic hit;
logic [31:0] core_address_reg;
logic [31:0] tag1,tag2;

logic [31:0]LRU_bit;
logic victim_way;

logic [31:0] old_core_addr;
logic control_different_pc;
logic [15:0] BWEB;

enum logic[2:0] { 
        IDLE,
        ADDRESS,
        DATA,
        NO_HIT,
        CACHE_RENEW,
        DATA_RENEW
}state,next_state;

always @(posedge clk or posedge rst) begin
  if (rst) begin
    state <= IDLE;
  end else begin
    state <= next_state;
  end
end

always_comb begin
  case (state)
    IDLE:begin
      next_state = (WFI_take_reg || core_addr == 32'h3000_0000)?IDLE:ADDRESS;
    end
    ADDRESS:begin 
      next_state = (control_different_pc || WFI_take_reg)?IDLE:
                   (hit)      ? DATA    : NO_HIT;
    end  
    DATA:begin
      next_state = IDLE;
    end
    NO_HIT:begin
      next_state = (I_req)  ?  CACHE_RENEW : NO_HIT;
    end
    CACHE_RENEW:begin 
      next_state = (~I_wait)?  DATA_RENEW  : CACHE_RENEW;
    end
    DATA_RENEW:begin
      next_state = IDLE;
    end 
    default:next_state = IDLE;
  endcase
end
assign TA_read = (state == ADDRESS);

assign index = core_addr [8:4];
// assign index = (state == IDLE)? core_addr [8:4] : (state != IDLE) ? core_address_reg [8:4] : 5'd0;
assign tag1 = (state == ADDRESS && valid1)?{9'd0,TA_out1}:32'd0;
assign tag2 = (state == ADDRESS && valid2)?{9'd0,TA_out2}:32'd0;

//hit判斷
assign hit =  (state == ADDRESS)?(hit1 || hit2):1'b0;
assign hit1 = (state == ADDRESS && valid1 && (tag1[22:0] == core_addr[31:9]));

assign hit2 = (state == ADDRESS && valid2 && (tag2[22:0] == core_addr[31:9]));
assign hit_select = (hit1)?2'b01:(hit2)?2'b10:2'b00;//hit1 2'b01,hit2 2'b10
//
assign control_different_pc = (core_addr != core_address_reg);

assign TA_write = (state == CACHE_RENEW && ~I_wait)? 1'b0 : 1'b1;//read : high

assign I_req = (state == NO_HIT);
assign core_wait = (state == DATA || state == DATA_RENEW )?1'b0:1'b1;
//刷新DATA
// assign I_addr = (state == NO_HIT)?{core_addr[31:4],{4'd0}} : 32'd0;
assign I_addr = {core_addr[31:4],{4'd0}};
assign DA_in  = (state == CACHE_RENEW && ~I_wait)?I_out:128'd0;
assign BWEB   = (state == CACHE_RENEW && ~I_wait)?16'd0:16'hFFFF;
assign TA_in  = (state == CACHE_RENEW && ~I_wait)?core_addr[31:9]:23'd0;
//LRU計數器
always @(posedge clk or posedge rst) begin
  if (rst) begin
      LRU_bit <= 32'd0;
  end else begin
    if (hit1)
      LRU_bit[index] <= 1'b0;  // way1 是最新
    else if (hit2)
      LRU_bit[index] <= 1'b1;  // way2 是最新
    else 
      LRU_bit <= LRU_bit;  
  end  
end
//判斷誰最近用
assign victim_way = (LRU_bit[index] == 1'b0) ? 1'b1 : 1'b0;
assign renew = (state == CACHE_RENEW); 
// LRU_bit = 0 >> 代表 way1 最新 >> 換掉 way2 victim=1'b1
// LRU_bit = 1 >> 代表 way2 最新 >> 換掉 way1 victim=1'b0

always @(posedge clk or posedge rst) begin
  if(rst) begin
    core_address_reg <= 32'd0;
  end else begin
    core_address_reg <= (state == IDLE) ? core_addr : core_address_reg;
  end
end

// always @(posedge clk or posedge rst) begin
//   if(rst)begin
//     hit_reg <= 2'd0;
//   end else begin
//     hit_reg <= (state == IDLE)? 2'd0 :
//                (state == ADDRESS) ? hit_select : hit_reg;   
//   end
// end

always @(posedge clk or posedge rst) begin
  if (rst) begin
    data <= 128'd0;
  end else begin
    data <= (state == IDLE)?128'd0:
            (state == ADDRESS)?DA_out :
            (next_state == DATA_RENEW)?I_out: data;
  end
end
logic [1:0]block_offset ;
assign block_offset = core_addr [3:2];

always_comb begin
  if (state == DATA || state == DATA_RENEW) begin
      case (block_offset)
        2'b00:begin
          core_out = data[31:0];
        end
        2'b01:begin
          core_out = data[63:32];
        end 
        2'b10:begin
          core_out = data[95:64];
        end
        2'b11:begin
          core_out = data[127:96];
        end
      endcase
    end else core_out = 32'd0;
end 


  IM_data_array_wrapper DA(
    .A(index),
    .DO(DA_out),
    .DI(DA_in),
    .CK(clk),
    .BWEB(BWEB),	// each bit control 1 byte, 128=16*8 bits active low
    .hit_select(hit_select),
    .victim_way(victim_way),
    .renew(renew),
    .CS(1'b1)
  );

   
  IM_tag_array_wrapper  TA(
    .A(index),
    .DO1(TA_out1),
    .DO2(TA_out2),
    .DI(TA_in),
    .CK(clk),
    .RST(rst),
    .victim_way(victim_way),
    .renew(renew),
    .WEB(TA_write),
    .OE(TA_read),
    .valid1(valid1),
    .valid2(valid2)
    
  );

endmodule