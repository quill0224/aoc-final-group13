// =============================================================================
// axi_mem_model.sv — AXI4 Slave Memory Model (for TB use only)
// 32-bit data width, INCR burst only
// Simulates DRAM for DMA read/write testing
// =============================================================================
`ifndef AXI_MEM_MODEL_SV
`define AXI_MEM_MODEL_SV

module axi_mem_model #(
    parameter MEM_DEPTH = 65536,    // 256KB word-addressable
    parameter LATENCY   = 2         // AR→R first beat latency (cycles)
)(
    input  logic        clk,
    input  logic        rst,

    // AR channel
    input  logic [3:0]  ARID,
    input  logic [31:0] ARADDR,
    input  logic [7:0]  ARLEN,
    input  logic [2:0]  ARSIZE,
    input  logic [1:0]  ARBURST,
    input  logic        ARVALID,
    output logic        ARREADY,

    // R channel
    output logic [3:0]  RID,
    output logic [31:0] RDATA,
    output logic [1:0]  RRESP,
    output logic        RLAST,
    output logic        RVALID,
    input  logic        RREADY,

    // AW channel
    input  logic [3:0]  AWID,
    input  logic [31:0] AWADDR,
    input  logic [7:0]  AWLEN,
    input  logic [2:0]  AWSIZE,
    input  logic [1:0]  AWBURST,
    input  logic        AWVALID,
    output logic        AWREADY,

    // W channel
    input  logic [31:0] WDATA,
    input  logic [3:0]  WSTRB,
    input  logic        WLAST,
    input  logic        WVALID,
    output logic        WREADY,

    // B channel
    output logic [3:0]  BID,
    output logic [1:0]  BRESP,
    output logic        BVALID,
    input  logic        BREADY
);
    // -------------------------------------------------------------------------
    // Memory array (32-bit word addressed)
    // -------------------------------------------------------------------------
    logic [31:0] mem [0:MEM_DEPTH-1];

    // Preload task (called from C++ via DPI or directly in SV)
    task automatic preload_word(input int addr_word, input logic [31:0] data);
        mem[addr_word] = data;
    endtask

    task automatic read_word(input int addr_word, output logic [31:0] data);
        data = mem[addr_word];
    endtask

    // -------------------------------------------------------------------------
    // READ path
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        AR_IDLE   = 2'd0,
        AR_WAIT   = 2'd1,   // latency countdown
        AR_BURST  = 2'd2
    } ar_state_t;

    ar_state_t ar_cs, ar_ns;

    logic [31:0] ar_addr_lat;
    logic [7:0]  ar_len_lat;
    logic [3:0]  ar_id_lat;
    logic [7:0]  ar_beat_cnt;
    logic [3:0]  ar_lat_cnt;    // latency counter

    always_ff @(posedge clk) begin
        if (rst) ar_cs <= AR_IDLE;
        else     ar_cs <= ar_ns;
    end

    always_comb begin
        ar_ns = ar_cs;
        case (ar_cs)
            AR_IDLE: if (ARVALID && ARREADY) ar_ns = AR_WAIT;
            AR_WAIT: if (ar_lat_cnt == 0)    ar_ns = AR_BURST;
            AR_BURST: if (RVALID && RREADY && RLAST) ar_ns = AR_IDLE;
            default: ar_ns = AR_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            ar_addr_lat  <= 32'd0;
            ar_len_lat   <= 8'd0;
            ar_id_lat    <= 4'd0;
            ar_beat_cnt  <= 8'd0;
            ar_lat_cnt   <= 4'd0;
        end else begin
            case (ar_cs)
                AR_IDLE: begin
                    if (ARVALID && ARREADY) begin
                        ar_addr_lat <= ARADDR;
                        ar_len_lat  <= ARLEN;
                        ar_id_lat   <= ARID;
                        ar_beat_cnt <= 8'd0;
                        ar_lat_cnt  <= LATENCY[3:0];
                    end
                end
                AR_WAIT: begin
                    if (ar_lat_cnt > 0) ar_lat_cnt <= ar_lat_cnt - 4'd1;
                end
                AR_BURST: begin
                    if (RVALID && RREADY) begin
                        ar_addr_lat <= ar_addr_lat + 32'd4;
                        ar_beat_cnt <= ar_beat_cnt + 8'd1;
                    end
                end
            endcase
        end
    end

    assign ARREADY = (ar_cs == AR_IDLE);
    assign RID     = ar_id_lat;
    assign RRESP   = 2'b00;
    assign RVALID  = (ar_cs == AR_BURST);
    assign RLAST   = (ar_cs == AR_BURST) && (ar_beat_cnt == ar_len_lat);
    assign RDATA   = (ar_cs == AR_BURST) ? mem[ar_addr_lat[31:2]] : 32'd0;

    // -------------------------------------------------------------------------
    // WRITE path
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        AW_IDLE  = 2'd0,
        AW_DATA  = 2'd1,
        AW_RESP  = 2'd2
    } aw_state_t;

    aw_state_t aw_cs, aw_ns;

    logic [31:0] aw_addr_lat;
    logic [7:0]  aw_len_lat;
    logic [3:0]  aw_id_lat;

    always_ff @(posedge clk) begin
        if (rst) aw_cs <= AW_IDLE;
        else     aw_cs <= aw_ns;
    end

    always_comb begin
        aw_ns = aw_cs;
        case (aw_cs)
            AW_IDLE: if (AWVALID && AWREADY) aw_ns = AW_DATA;
            AW_DATA: if (WVALID && WREADY && WLAST) aw_ns = AW_RESP;
            AW_RESP: if (BVALID && BREADY) aw_ns = AW_IDLE;
            default: aw_ns = AW_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            aw_addr_lat <= 32'd0;
            aw_len_lat  <= 8'd0;
            aw_id_lat   <= 4'd0;
        end else begin
            if (aw_cs == AW_IDLE && AWVALID && AWREADY) begin
                aw_addr_lat <= AWADDR;
                aw_len_lat  <= AWLEN;
                aw_id_lat   <= AWID;
            end
            if (aw_cs == AW_DATA && WVALID && WREADY) begin
                // write with byte strobe
                if (WSTRB[0]) mem[aw_addr_lat[31:2]][7:0]   <= WDATA[7:0];
                if (WSTRB[1]) mem[aw_addr_lat[31:2]][15:8]  <= WDATA[15:8];
                if (WSTRB[2]) mem[aw_addr_lat[31:2]][23:16] <= WDATA[23:16];
                if (WSTRB[3]) mem[aw_addr_lat[31:2]][31:24] <= WDATA[31:24];
                aw_addr_lat <= aw_addr_lat + 32'd4;
            end
        end
    end

    assign AWREADY = (aw_cs == AW_IDLE);
    assign WREADY  = (aw_cs == AW_DATA);
    assign BID     = aw_id_lat;
    assign BRESP   = 2'b00;
    assign BVALID  = (aw_cs == AW_RESP);

    // -------------------------------------------------------------------------
    // Init
    // -------------------------------------------------------------------------
    initial begin
        for (int i = 0; i < MEM_DEPTH; i++) mem[i] = 32'd0;
    end

endmodule

`endif