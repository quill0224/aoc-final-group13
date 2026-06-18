// Banked-output placeholder for TrIP MVP.
//
// Stores one reduced value per output coordinate (A row, B column). A later
// version can replace this with true banked scatter/gather storage.

module row_local_buffer #(
    parameter NUM_ROWS  = 2,
    parameter NUM_COLS  = 2,
    parameter DATA_WIDTH = 35,
    parameter NUM_OUTPUTS = NUM_ROWS * NUM_COLS
) (
    input  wire                         clk,
    input  wire                         reset,
    input  wire                         wr_en_i,
    input  wire [NUM_OUTPUTS-1:0]       wr_valid_i,
    input  wire [NUM_OUTPUTS*DATA_WIDTH-1:0] wr_data_i,

    output wire [NUM_OUTPUTS-1:0]       rd_valid_o,
    output wire [NUM_OUTPUTS*DATA_WIDTH-1:0] rd_data_o
);

    reg [NUM_OUTPUTS-1:0]        valid_mem;
    reg [DATA_WIDTH-1:0]         data_mem [0:NUM_OUTPUTS-1];

    integer i;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            valid_mem <= {NUM_OUTPUTS{1'b0}};
            for (i = 0; i < NUM_OUTPUTS; i = i + 1)
                data_mem[i] <= {DATA_WIDTH{1'b0}};
        end else if (wr_en_i) begin
            valid_mem <= wr_valid_i;
            for (i = 0; i < NUM_OUTPUTS; i = i + 1) begin
                data_mem[i] <= wr_data_i[i*DATA_WIDTH +: DATA_WIDTH];
            end
        end
    end

    assign rd_valid_o = valid_mem;

    genvar go;
    generate
        for (go = 0; go < NUM_OUTPUTS; go = go + 1) begin : gen_out
            assign rd_data_o[go*DATA_WIDTH +: DATA_WIDTH] = data_mem[go];
        end
    endgenerate

endmodule
