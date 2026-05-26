module switch_2x2 #(
    parameter DATA_W = 8
)(
    input  logic [DATA_W-1:0] in0,
    input  logic [DATA_W-1:0] in1,
    input  logic              sel,

    output logic [DATA_W-1:0] out0,
    output logic [DATA_W-1:0] out1
);

    always_comb begin
        if (!sel) begin
            out0 = in0;
            out1 = in1;
        end else begin
            out0 = in1;
            out1 = in0;
        end
    end

endmodule