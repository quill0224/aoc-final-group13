// Bitmask buffer for TrIP sparse fiber storage.
// Stores up to NUM_FIBERS fiber entries, each with:
//   - fiber ID (row_id for A side, col_id for B side)
//   - bitmask[K_BITS-1:0]  : which of the K slots are nonzero
//   - values[K_BITS-1:0]   : fixed-slot values (same width as bitmask slots)
//
// Uses fixed-slot layout (not compact), so k_sel from MFIU can index values
// directly without a prefix-sum lookup. See HARDWARE_STRUCTURE.md §23.3, §26.

module bitmask_buffer #(
    parameter NUM_FIBERS = 4,          // number of fiber entries stored
    parameter K_BITS     = 4,          // fiber dimension (nonzero slot count)
    parameter DATA_WIDTH = 16,         // value bit width
    parameter ID_WIDTH   = 4,          // fiber ID bit width
    parameter ADDR_WIDTH = $clog2(NUM_FIBERS)
) (
    input  wire                               clk,
    input  wire                               reset,

    // Write port — load one fiber per cycle
    input  wire                               wr_en_i,
    input  wire [ADDR_WIDTH-1:0]              wr_addr_i,
    input  wire [ID_WIDTH-1:0]                wr_id_i,
    input  wire [K_BITS-1:0]                  wr_mask_i,
    input  wire [K_BITS*DATA_WIDTH-1:0]       wr_values_i,

    // Read port — read one fiber per cycle (1-cycle latency)
    input  wire [ADDR_WIDTH-1:0]              rd_addr_i,
    output reg  [ID_WIDTH-1:0]                rd_id_o,
    output reg  [K_BITS-1:0]                  rd_mask_o,
    output reg  [K_BITS*DATA_WIDTH-1:0]       rd_values_o,

    // Convenience: indexed value read
    // Given rd_addr_i and k_sel_i, returns the single value at slot k
    input  wire [$clog2(K_BITS)-1:0]          k_sel_i,
    output wire [DATA_WIDTH-1:0]               k_value_o
);

    // Storage arrays
    reg [ID_WIDTH-1:0]          id_mem    [0:NUM_FIBERS-1];
    reg [K_BITS-1:0]            mask_mem  [0:NUM_FIBERS-1];
    reg [K_BITS*DATA_WIDTH-1:0] value_mem [0:NUM_FIBERS-1];

    integer i;

    // Write
    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < NUM_FIBERS; i = i + 1) begin
                id_mem[i]    <= {ID_WIDTH{1'b0}};
                mask_mem[i]  <= {K_BITS{1'b0}};
                value_mem[i] <= {(K_BITS*DATA_WIDTH){1'b0}};
            end
        end else if (wr_en_i) begin
            id_mem   [wr_addr_i] <= wr_id_i;
            mask_mem [wr_addr_i] <= wr_mask_i;
            value_mem[wr_addr_i] <= wr_values_i;
        end
    end

    // Read (registered, 1-cycle latency)
    always @(posedge clk) begin
        if (reset) begin
            rd_id_o     <= {ID_WIDTH{1'b0}};
            rd_mask_o   <= {K_BITS{1'b0}};
            rd_values_o <= {(K_BITS*DATA_WIDTH){1'b0}};
        end else begin
            rd_id_o     <= id_mem   [rd_addr_i];
            rd_mask_o   <= mask_mem [rd_addr_i];
            rd_values_o <= value_mem[rd_addr_i];
        end
    end

    // Single-slot value extraction (combinational, from registered output)
    assign k_value_o = rd_values_o[k_sel_i * DATA_WIDTH +: DATA_WIDTH];

endmodule
