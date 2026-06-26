module branch_predictor(
    input clk,rst,
    input branch_result,
    input [6:0] E_op,
    input  logic B_type,
    input  logic jb,
    output logic address_sl,
    output logic [1:0]state


);
logic [1:0] next_state;

parameter weakly_not_taken   = 2'd0,
          strongly_not_taken = 2'd1,
          weakly_taken       = 2'd2,
          strongly_taken     = 2'd3;

// enum logic [1:0]{
//     weakly_not_taken,strongly_not_taken,weakly_taken,strongly_taken
// }state,next_state;


always @(posedge clk or posedge rst) begin
    if (rst) begin
        state   <= 2'd0;
    end
    else begin
        state   <= next_state;
    end
end


always_comb begin
    if (E_op == 7'b1100011) begin
        case (state)
            strongly_not_taken:begin
                if (branch_result)
                    next_state = weakly_not_taken;
                else 
                    next_state = strongly_not_taken;
            end
            weakly_not_taken:begin
                if (branch_result) begin
                    next_state = weakly_taken;
                end else begin
                    next_state = strongly_not_taken;
                end
            end 
            weakly_taken:begin
                if (branch_result) begin
                    next_state = strongly_taken;
                end else begin
                    next_state = weakly_not_taken;
                end
            end
            default:begin//strongly_taken
                if (branch_result) begin
                    next_state = strongly_taken;
                end else begin
                    next_state = weakly_taken;
                end
            end 
        endcase
    end else begin
        next_state = state;
    end
end
always_comb begin
    if (jb) begin
        address_sl = 1'b0;
    end else begin
        if (B_type) begin
            if (state == weakly_taken || state == strongly_taken) begin
                address_sl = 1'b1;
            end else
                address_sl = 1'b0;
            end
        else
        address_sl = 1'b0;
    end
end
        
// assign address_sl = 1'b0;

endmodule