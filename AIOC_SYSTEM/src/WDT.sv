module WDT(
    input                       clk,
    input                       rst,
    input                       clk2,
    input                       rst2,
    input                       WDEN,
    input                       WDLIVE,
    input [`AXI_DATA_BITS-1:0]  WTOCNT,

    output logic                WTO
);

// CDC signals
logic                       q0,q1, q2, q3;
logic                       clk3;

// Watch Dog Counter
logic [`AXI_DATA_BITS-1:0]  count;

assign WTO = (count == WTOCNT) && (count != `AXI_DATA_BITS'd0);

// cross clk2 to clk
// generate clk3 in clk domain with clk2 period
always_ff@(posedge clk2)begin
	if(!rst2)
		q0 <= 1'b0;
	else
		q0 <= !q0;
end

assign clk3 = q2 ^ q3;

always_ff@(posedge clk or posedge rst)
begin
    if(rst)begin
        q1      <= 1'b0;
        q2      <= 1'b0;
        q3      <= 1'b0;
    end
    else begin
        q1      <= clk2;
        q2      <= q1;
        q3      <= q2; 
    end
end

// Watch Dog Timer
always_ff@(posedge clk or posedge rst)
begin
    if(rst)begin
        count   <= `AXI_DATA_BITS'd0;
    end
    else if(WDEN)begin
        if(WDLIVE)begin
            count   <= `AXI_DATA_BITS'd0;
        end
        else if(count >= WTOCNT)begin
            count   <= `AXI_DATA_BITS'd0;
        end
        else if(clk3)begin
            count   <= count + 32'd1;
        end
        else begin
            count   <= count;
        end
    end
    else begin
        count   <= count;
    end
end

endmodule