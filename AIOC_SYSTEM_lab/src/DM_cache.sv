module DM_cache (
  input clk,rst,
  input [31:0]            core_addr,
  input [31:0]            core_in,
  input [1:0]             core_inst,//2'b10 L,2'b11 S 
  input [3:0]             wstrb,

  input [127:0]           D_in,
  input                   D_wait,
  input                   B_DONE,
  
  output logic [31:0]     core_out,
  output logic            core_wait,
  
  output logic            D_req,
  output logic [31:0]     D_addr,
  output logic            DATA_RENEW_DONE

);
// 地址分解保持不變，假設為 32-bit 地址，128-bit (16-byte) 快取行，32 個 set (5-bit index)
`define Tag            core_addr[31:9]
`define set_index      core_addr[8:4]
`define byte_offset    core_addr[1:0]

logic valid1,valid2;
logic [4:0]   index;
logic TA_read,DA_read;
logic [22:0] TA_in,TA_out1, TA_out2;
logic [15:0] DA_write;
logic [127:0] DA_in,DA_out;
logic hit1,hit2;
logic [1:0]hit_select;
logic [127:0] data; // 暫存 DA_out
logic [31:0]core_address_reg;
logic hit;
logic [31:0]tag1,tag2;

logic [31:0] LRU_bit;
logic victim_way;
logic [15:0] BWEB;
logic WEB;
logic [1:0]block_offset;
logic      s_hit_renew,L_NO_HIT_renew;
logic is_non_cacheable;
always_comb begin
  is_non_cacheable = (core_addr[31:16] == 16'h0005) || (core_addr[31:16] == 16'h1001) || (core_addr[31:16] == 16'h1002);
end

// 狀態機定義
enum logic[2:0] { 
        IDLE,
        ADDRESS,
        L_HIT,
        S_HIT,
        NO_HIT,
        CACHE_RENEW,
        DATA_PACK,
        DATA_RENEW
} state,next_state;

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
      next_state = //(D_wait)? IDLE : 
                   (core_inst == 2'b10 || core_inst == 2'b11) ? ADDRESS : IDLE;
    end
    ADDRESS:begin 
      next_state = 
                   (hit && core_inst == 2'b10)  ? L_HIT :
                   (hit && core_inst == 2'b11)  ? S_HIT :
                   NO_HIT;
    end
    L_HIT:begin
      next_state = IDLE;
    end
    S_HIT:begin
      next_state = (B_DONE)?IDLE:S_HIT;
    end
    NO_HIT:begin
    // 使用 D_req
    next_state = (D_req && core_inst ==2'b10)  ?  CACHE_RENEW: (~B_DONE)?NO_HIT: IDLE;
    end
    CACHE_RENEW:begin 
    // 使用 D_wait
      next_state = (~D_wait)                   ?  DATA_PACK  : CACHE_RENEW;
    end
    DATA_PACK:begin
      next_state = DATA_RENEW;
    end
    DATA_RENEW:begin
      next_state = IDLE;
    end
  endcase
end

// assign DA_read = (state == HIT); 
assign TA_read = (state == ADDRESS);

assign index = core_addr[8:4];
assign tag1 = (state == ADDRESS && valid1)?{9'd0,TA_out1}:32'd0;
assign tag2 = (state == ADDRESS && valid2)?{9'd0,TA_out2}:32'd0;

// hit 判斷 - 保持不變 (假設 TA_out1/2 是 Tag + Valid bit)
assign hit = (state == ADDRESS && !is_non_cacheable)?(hit1 || hit2):1'b0;
 
assign hit1 = (state == ADDRESS && valid1 && (tag1[22:0] == core_addr[31:9])); 
assign hit2 = (state == ADDRESS && valid2 && (tag2[22:0] == core_addr[31:9])); 
assign hit_select = (hit1)?2'b01:(hit2)?2'b10:2'b00;


assign s_hit_renew = (state == S_HIT);
assign L_NO_HIT_renew = (state == DATA_PACK && !is_non_cacheable);

assign D_req = ( state == NO_HIT && core_inst == 2'b10);

// 外部地址: 
assign D_addr = {core_addr[31:4], 4'd0};
// 外部寫入/輸入
assign  DATA_RENEW_DONE = (state == DATA_RENEW || state == L_HIT);

// assign DA_in  = (state == CACHE_RENEW && ~D_wait)?D_in:128'd0;  //
// 
assign TA_in  = (state == CACHE_RENEW && ~D_wait)?core_addr[31:9]:23'd0; 
// 
assign core_wait = (state == IDLE || state == L_HIT || state == DATA_RENEW )?1'b0:1'b1;
// LRU 計數器 - 保持不變
always @(posedge clk or posedge rst) begin
  if (rst) begin
      LRU_bit <= 32'd0;
  end else begin
    if (hit1) 
      LRU_bit[index] <= 1'b0; // way1 是最新
    else if (hit2)
      LRU_bit[index] <= 1'b1; // way2 是最新
    else
      LRU_bit <= LRU_bit;
  end
end

// 判斷替換方式
assign victim_way = (LRU_bit[index] == 1'b0) ? 1'b1 : 1'b0;
assign renew = (state == CACHE_RENEW && !is_non_cacheable);  

// 註冊 core_addr - 保持不變
always @(posedge clk or posedge rst) begin
  if(rst) begin
    core_address_reg <= 32'd0;
  end else begin
    core_address_reg <= (state == IDLE) ? core_addr : core_address_reg;
  end
end

// 註冊 hit_select - 保持不變
// always @(posedge clk or posedge rst) begin
//   if(rst)begin
//     hit_reg <= 2'd0;
//   end else begin
//     hit_reg <=  (state == IDLE)? 2'd0 :
//                 (state == ADDRESS) ? hit_select : hit_reg;
//   end
// end


always @(posedge clk or posedge rst) begin
  if (rst) begin
    data <= 128'd0;
  end else begin
    data <= (state == IDLE)?128'd0:
            (state == ADDRESS)?DA_out :
            (next_state == DATA_RENEW)?D_in: data;
  end
end


assign block_offset = core_addr [3:2];
always_comb begin
  if (state == ADDRESS && core_inst == 2'b10) begin//HIT讀
    WEB = 1'b1;//write enable active low
    BWEB = 16'hFFFF;
    DA_in = 128'd0;
  end else if (state == S_HIT) begin
    WEB = 1'b0;
    case (block_offset)
      2'b00:begin
        DA_in = {96'd0,core_in};
        BWEB  = {12'hFFF,~wstrb};
      end
      2'b01:begin
        DA_in = {64'd0,core_in,32'd0};
        BWEB  = {8'hFF,~wstrb,4'hF};
      end
      2'b10:begin
        DA_in = {32'd0,core_in,64'd0};
        BWEB  = {4'hF,~wstrb,8'hFF};
      end
      2'b11:begin
        DA_in = {core_in,96'd0};
        BWEB  = {~wstrb,12'hFFF};
      end
    endcase
  end else if (state == CACHE_RENEW && ~D_wait) begin
    WEB = 1'b0;
    DA_in = 128'd0;
    BWEB  = 16'd0;
  end else if (state == DATA_PACK) begin
    WEB = 1'b0;
    DA_in = D_in;
    BWEB = 16'd0;
  end else begin
    WEB = 1'b1;
    DA_in = 128'd0;
    BWEB = 16'hFFFF;
  end
end


// 輸出資料到 CPU (core_out)
always_comb begin
  if (state == L_HIT || state == DATA_RENEW) begin
      if (is_non_cacheable) begin
        core_out = data[31:0];
      end else begin
        // 根據 block_offset 選取 word
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
      end
    end else core_out = 32'd0;
end 

// 資料陣列實例化 
  DM_data_array_wrapper DA(
    .A(index),
    .DO(DA_out),
    .DI(DA_in),
    .CK(clk),
    .RST(rst),
    .s_hit_renew(s_hit_renew),
    .L_NO_HIT_renew(L_NO_HIT_renew),
    // 
    .BWEB(BWEB), 
    .hit_select(hit_select),
    .victim_way(victim_way),
    .WEB(WEB),
    .CS(1'b1)
);

// 標籤陣列實例化 
  DM_tag_array_wrapper  TA(
    .A(index),
    .DO1(TA_out1),
    .DO2(TA_out2),
    .DI(TA_in),
    .CK(clk),
    .OE(TA_read),
    .RST(rst),
    .victim_way(victim_way),
    .renew(renew),
    .WEB(WEB),
    .valid1(valid1),
    .valid2(valid2)
);

endmodule