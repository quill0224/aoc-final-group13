module mux_ad(
    input [31:0] address_pre,
    input [31:0] address_ori,
    input address_sl,
    output logic [31:0] mux_ad_out
);
always_comb begin
    if (address_sl) begin
        mux_ad_out = address_pre;
    end else begin
        mux_ad_out = address_ori;
    end
end 





endmodule