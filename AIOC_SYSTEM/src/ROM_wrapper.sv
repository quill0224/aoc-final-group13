module ROM_wrapper (
  output OE,CS,
  output [11:0] A,
  input [31:0] DO,

  input ACLK,ARESETn,

  input [3:0]         ARID_S,
  input [31:0]        ARADDR_S,
  input [3:0]         ARLEN_S,
  input [2:0]         ARSIZE_S,//3'd2
  input [1:0]         ARBURST_S,//2'b01
  input               ARVALID_S,
  output logic        ARREADY_S,    


  output logic [3:0]  RID_S,
  output logic [31:0] RDATA_S,
  output logic [1:0]  RRESP_S,
  output logic        RLAST_S,
  output logic        RVALID_S,
  input               RREADY_S
);

logic [31:0] araddr;
logic [4:0]  AR_addr_count;
logic [4:0]  arlength;

enum logic [2:0] {
          IDLE,
          AR_READY,
          R_WAIT,
          R_DATA
} state,next_state;

always @(posedge ACLK or negedge ARESETn) begin
  if(!ARESETn)
      state <= IDLE; 
  else
      state <= next_state;
end

always_comb begin
  case (state)
    IDLE:begin
      next_state = (ARVALID_S)?AR_READY:IDLE;
    end 
    AR_READY:begin
      next_state = (ARVALID_S && ARREADY_S)?R_WAIT:AR_READY;
    end
    R_WAIT:begin
      next_state = R_DATA;
    end
    R_DATA:begin
      next_state = (RVALID_S && RREADY_S && RLAST_S)?IDLE:
                   (RVALID_S && RREADY_S && ~RLAST_S)?R_WAIT:R_DATA;
    end
    default: next_state = IDLE;
  endcase
end

assign ARREADY_S = (state == AR_READY);
assign RVALID_S  = (state == R_DATA);
assign A  = (state == R_WAIT)?araddr[13:2]:12'd0;
assign OE = (state == R_DATA);
assign CS = (state == R_WAIT);


always @ (posedge ACLK or negedge ARESETn)begin
  if (~ARESETn) begin
    araddr <= 32'd0;
    AR_addr_count <= 5'd0;
    arlength <= 5'd0;
  end else if (state == IDLE)begin
    araddr <= 32'd0;
    AR_addr_count <= 5'd0;
    arlength <= 5'd0;
  end else if (ARREADY_S && ARVALID_S)begin
    araddr <= ARADDR_S;
    arlength <= {1'd0,ARLEN_S};
  end else begin
    if ((AR_addr_count < (arlength + 5'd1)) && (next_state == R_DATA) && (state == R_WAIT)) begin
      if (arlength == 5'd0) begin
        araddr <= araddr;
        AR_addr_count <= AR_addr_count;
      end else begin
        araddr        <=    araddr + 32'd4;
        AR_addr_count <=    AR_addr_count + 5'd1;
      end
    end else begin
        araddr        <=    araddr;
        AR_addr_count <=    AR_addr_count;
    end
  end
end

assign RLAST_S = ((AR_addr_count == arlength + 5'd1) && (state == R_DATA));

always @ (posedge ACLK or negedge ARESETn) begin
  if (!ARESETn) begin
    RID_S <= 4'd0;
  end else begin 
    if (ARREADY_S && ARVALID_S) begin
      RID_S <= ARID_S;
    end else begin
      RID_S <= RID_S;   
    end
  end
end

// always @ (posedge ACLK or negedge ARESETn) begin
//   if (~ARESETn) begin
//     RDATA_S <= 32'd0;
//   end else if(state == IDLE) begin
//     RDATA_S <= 32'd0;
//   end else begin
//     RDATA_S <= (state == R_DATA)?DO:RDATA_S;
//   end
// end
assign RDATA_S = DO;
assign RRESP_S = 2'b00;

endmodule