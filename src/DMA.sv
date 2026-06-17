`include "AXI/AXI_define.svh"
`include "ASIC.svh"

// =============================================================================
// dma.sv — AXI4 Master DMA for Trapezoid-Lite ASIC
//
// 1. AXI4 Master read/write (INCR burst)
// 2. Auto-chunk requests > 1024B into 256-beat bursts
// 3. Fetch  (DRAM→GLB): direct write, no FIFO
// 4. Writeback (GLB→DRAM): 16-deep FIFO to absorb WREADY stalls
//
// Reset  : active-high rst
// DMA_done : 1-cycle pulse; caller must latch with a sticky flag
// Re-trigger : DMA only accepts new DMA_en in IDLE state
// =============================================================================

module DMA (
    input  logic                        clk,
    input  logic                        rst,

    // Controller interface
    input  logic                        DMA_en,
    input  logic [1:0]                  DMA_mode,       // 0/1=Fetch A/B, 3=Writeback C
    input  logic [`AXI_ADDR_BITS-1:0]   DMA_DRAM_ADDR,
    input  logic [`GLB_ADDR_BITS-1:0]   DMA_GLB_ADDR,
    input  logic [31:0]                 DMA_len,        // bytes, must be 4B-aligned
    output logic                        DMA_done,       // 1-cycle pulse

    // GLB interface (DMA is master)
    output logic                        glb_en,
    output logic                        glb_we,
    output logic [3:0]                  glb_wstrb,
    output logic [`GLB_ADDR_BITS-1:0]   glb_addr,
    output logic [31:0]                 glb_wdata,
    input  logic [31:0]                 glb_rdata,

    // AXI4 AR channel
    output logic [`AXI_ID_BITS-1:0]     ARID,
    output logic [`AXI_ADDR_BITS-1:0]   ARADDR,
    output logic [`AXI_LEN_BITS-1:0]    ARLEN,
    output logic [`AXI_SIZE_BITS-1:0]   ARSIZE,
    output logic [1:0]                  ARBURST,
    output logic                        ARVALID,
    input  logic                        ARREADY,

    // AXI4 R channel
    input  logic [`AXI_ID_BITS-1:0]     RID,
    input  logic [`AXI_DATA_BITS-1:0]   RDATA,
    input  logic [1:0]                  RRESP,
    input  logic                        RLAST,
    input  logic                        RVALID,
    output logic                        RREADY,

    // AXI4 AW channel
    output logic [`AXI_ID_BITS-1:0]     AWID,
    output logic [`AXI_ADDR_BITS-1:0]   AWADDR,
    output logic [`AXI_LEN_BITS-1:0]    AWLEN,
    output logic [`AXI_SIZE_BITS-1:0]   AWSIZE,
    output logic [1:0]                  AWBURST,
    output logic                        AWVALID,
    input  logic                        AWREADY,

    // AXI4 W channel
    output logic [`AXI_DATA_BITS-1:0]   WDATA,
    output logic [`AXI_STRB_BITS-1:0]   WSTRB,
    output logic                        WLAST,
    output logic                        WVALID,
    input  logic                        WREADY,

    // AXI4 B channel
    input  logic [`AXI_ID_BITS-1:0]     BID,
    input  logic [1:0]                  BRESP,
    input  logic                        BVALID,
    output logic                        BREADY
);

    // =========================================================================
    // FSM
    // =========================================================================
    typedef enum logic [2:0] {
        IDLE    = 3'd0,
        REQ_AR  = 3'd1,
        FETCH_R = 3'd2,
        REQ_AW  = 3'd3,
        WB_FILL = 3'd4,
        WB_W    = 3'd5,
        WB_B    = 3'd6,
        DONE    = 3'd7
    } dma_state_t;

    dma_state_t state, next_state;

    // =========================================================================
    // Chunking
    // Max burst: 256 beats × 4B = 1024B
    // burst_beats_m1 : ARLEN/AWLEN value (beats - 1), 8-bit
    // total_beats    : 9-bit to prevent burst_beats_m1+1 overflow
    // =========================================================================
    logic [31:0]             rem_bytes;
    logic [31:0]             cur_dram_addr;
    logic [`GLB_ADDR_BITS-1:0] cur_glb_addr;   // sized to GLB space, not 32-bit

    logic [31:0] burst_bytes;
    logic [7:0]  burst_beats_m1;
    logic [8:0]  total_beats;
    logic [8:0]  beats_transferred;

    assign burst_bytes    = (rem_bytes > 32'd1024) ? 32'd1024 : rem_bytes;
    assign burst_beats_m1 = burst_bytes[9:2] - 8'd1;
    assign total_beats    = {1'b0, burst_beats_m1} + 9'd1;

    // =========================================================================
    // Writeback FIFO (16 entries × 32-bit)
    // Decouples GLB 1-cycle read latency from AXI WREADY stalls
    // =========================================================================
    logic [31:0] fifo [0:15];
    logic [4:0]  fifo_cnt;
    logic [3:0]  wr_ptr, rd_ptr;

    logic glb_rd_req;
    logic glb_rd_valid;

    // 6-bit addition to avoid 5-bit overflow in fifo_cnt + glb_rd_valid
    logic [5:0] fifo_used;
    assign fifo_used  = {1'b0, fifo_cnt} + {5'd0, glb_rd_valid};
    assign glb_rd_req = ((state == WB_FILL) || (state == WB_W)) &&
                        (fifo_used < 6'd15)                      &&
                        (beats_transferred < total_beats);

    always_ff @(posedge clk) begin
        if (rst) glb_rd_valid <= 1'b0;
        else     glb_rd_valid <= glb_rd_req;
    end

    logic fifo_push, fifo_pop;
    assign fifo_push = glb_rd_valid;
    assign fifo_pop  = (state == WB_W) && WVALID && WREADY;

    always_ff @(posedge clk) begin
        if (rst || state == IDLE || state == REQ_AW) begin
            fifo_cnt <= 5'd0;
            wr_ptr   <= 4'd0;
            rd_ptr   <= 4'd0;
        end else begin
            if      ( fifo_push && !fifo_pop) fifo_cnt <= fifo_cnt + 5'd1;
            else if (!fifo_push &&  fifo_pop) fifo_cnt <= fifo_cnt - 5'd1;

            if (fifo_push) begin
                fifo[wr_ptr] <= glb_rdata;
                wr_ptr       <= wr_ptr + 4'd1;
            end
            if (fifo_pop) rd_ptr <= rd_ptr + 4'd1;
        end
    end

    // =========================================================================
    // w_beats_sent: tracks beats sent on W channel for WLAST generation
    // =========================================================================
    logic [8:0] w_beats_sent;

    always_ff @(posedge clk) begin
        if (rst || state == REQ_AW) w_beats_sent <= 9'd0;
        else if (WVALID && WREADY)  w_beats_sent <= w_beats_sent + 9'd1;
    end

    // =========================================================================
    // FSM State Register
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) state <= IDLE;
        else     state <= next_state;
    end

    // =========================================================================
    // FSM Next-State Logic
    // =========================================================================
    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                if (DMA_en) begin
                    if (DMA_mode == 2'd3) next_state = REQ_AW;
                    else                  next_state = REQ_AR;
                end
            end

            REQ_AR: begin
                if (ARVALID && ARREADY) next_state = FETCH_R;
            end

            FETCH_R: begin
                if (RVALID && RREADY && RLAST) begin
                    // rem_bytes still holds pre-decrement value here
                    if (rem_bytes == burst_bytes) next_state = DONE;
                    else                          next_state = REQ_AR;
                end
            end

            REQ_AW: begin
                if (AWVALID && AWREADY) next_state = WB_FILL;
            end

            WB_FILL: begin
                // Pre-fill FIFO before starting W channel to avoid bubbles.
                // Corner case (total_beats==1): beats_transferred reaches
                // total_beats before glb_rd_valid arrives; WB_W will stall
                // on fifo_cnt==0 until glb_rd_valid fires (1 cycle later).
                if (fifo_cnt >= 5'd2 || beats_transferred == total_beats)
                    next_state = WB_W;
            end

            WB_W: begin
                if (WVALID && WREADY && WLAST) next_state = WB_B;
            end

            WB_B: begin
                if (BVALID && BREADY) begin
                    if (rem_bytes == burst_bytes) next_state = DONE;
                    else                          next_state = REQ_AW;
                end
            end

            DONE: begin
                // 1-cycle pulse state; DMA_done goes high this cycle only
                next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    // =========================================================================
    // Datapath — Address and Counter Updates
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            rem_bytes         <= 32'd0;
            cur_dram_addr     <= 32'd0;
            cur_glb_addr      <= {`GLB_ADDR_BITS{1'b0}};
            beats_transferred <= 9'd0;
        end else begin

            if (state == IDLE && DMA_en) begin
                rem_bytes     <= DMA_len;
                cur_dram_addr <= DMA_DRAM_ADDR;
                cur_glb_addr  <= DMA_GLB_ADDR;
            end

            else if (state == REQ_AR || state == REQ_AW) begin
                beats_transferred <= 9'd0;
            end

            else if (state == FETCH_R) begin
                if (RVALID && RREADY) begin
                    cur_glb_addr  <= cur_glb_addr  + `GLB_ADDR_BITS'd4;
                    cur_dram_addr <= cur_dram_addr + 32'd4;
                    if (RLAST && (rem_bytes != burst_bytes)) begin
                        rem_bytes <= rem_bytes - burst_bytes;
                    end
                end
            end

            else if (state == WB_FILL || state == WB_W) begin
                if (glb_rd_req) begin
                    cur_glb_addr      <= cur_glb_addr + `GLB_ADDR_BITS'd4;
                    beats_transferred <= beats_transferred + 9'd1;
                end
                if (state == WB_W && WVALID && WREADY && WLAST) begin
                    cur_dram_addr <= cur_dram_addr + burst_bytes;
                    rem_bytes     <= rem_bytes - burst_bytes;
                end
            end

        end
    end

    // =========================================================================
    // Output Assignments
    // =========================================================================

    assign DMA_done = (state == DONE);

    // GLB: fetch writes directly; writeback reads via glb_rd_req
    assign glb_we    = (state == FETCH_R) && RVALID && RREADY;
    assign glb_en    = glb_we || glb_rd_req;
    assign glb_wstrb = 4'b1111;
    assign glb_wdata = RDATA;
    assign glb_addr  = cur_glb_addr;

    // AR channel
    assign ARID    = `AXI_ID_BITS'd2;
    assign ARADDR  = cur_dram_addr;
    assign ARLEN   = burst_beats_m1;
    assign ARSIZE  = `AXI_SIZE_WORD;
    assign ARBURST = `AXI_BURST_INC;
    assign ARVALID = (state == REQ_AR);

    // R channel: GLB accepts data unconditionally, so RREADY is always high
    assign RREADY  = (state == FETCH_R);

    // AW channel
    assign AWID    = `AXI_ID_BITS'd2;
    assign AWADDR  = cur_dram_addr;
    assign AWLEN   = burst_beats_m1;
    assign AWSIZE  = `AXI_SIZE_WORD;
    assign AWBURST = `AXI_BURST_INC;
    assign AWVALID = (state == REQ_AW);

    // W channel
    // WLAST: w_beats_sent counts from 0; last beat index == burst_beats_m1
    assign WDATA  = fifo[rd_ptr];
    assign WSTRB  = 4'b1111;
    assign WVALID = (state == WB_W) && (fifo_cnt > 5'd0);
    assign WLAST  = (state == WB_W) && (w_beats_sent == {1'b0, burst_beats_m1});

    // B channel
    assign BREADY = (state == WB_B);

    // =========================================================================
    // Simulation Assertions
    // =========================================================================
`ifdef SIMULATION

    logic [15:0] dma_active_cnt;   // must be declared before procedural blocks

    // DMA_len must be non-zero and 4B-aligned; BIAS mode unsupported
    always_ff @(posedge clk) begin
        if (state == IDLE && DMA_en) begin
            assert (DMA_len > 32'd0)
                else $error("[DMA %0t] DMA_len=0", $time);
            assert (DMA_len[1:0] == 2'b00)
                else $error("[DMA %0t] DMA_len=0x%08X not 4B-aligned", $time, DMA_len);
            assert (DMA_mode != 2'd2)
                else $error("[DMA %0t] DMA_mode=BIAS not supported", $time);
        end
    end

    // FIFO overflow / underflow
    always_ff @(posedge clk) begin
        if (fifo_push)
            assert (fifo_cnt < 5'd16)
                else $error("[DMA %0t] FIFO overflow: cnt=%0d", $time, fifo_cnt);
        if (fifo_pop)
            assert (fifo_cnt > 5'd0)
                else $error("[DMA %0t] FIFO underflow: cnt=%0d", $time, fifo_cnt);
    end

    // Unexpected RVALID outside FETCH_R
    always_ff @(posedge clk) begin
        if (RVALID && state != FETCH_R)
            $warning("[DMA %0t] RVALID=1 in state %s; ignored", $time, state.name());
    end

    // AXI response must be OKAY
    always_ff @(posedge clk) begin
        if (BVALID && BREADY)
            assert (BRESP == 2'b00)
                else $error("[DMA %0t] BRESP=%02b (expected OKAY)", $time, BRESP);
        if (RVALID && RREADY)
            assert (RRESP == 2'b00)
                else $error("[DMA %0t] RRESP=%02b (expected OKAY)", $time, RRESP);
    end

    // beats_transferred must not exceed total_beats
    always_ff @(posedge clk) begin
        if (state == WB_FILL || state == WB_W)
            assert (beats_transferred <= total_beats)
                else $error("[DMA %0t] beats_transferred=%0d > total_beats=%0d",
                            $time, beats_transferred, total_beats);
    end

    // DMA completion watchdog
    always_ff @(posedge clk) begin
        if (rst || state == IDLE) dma_active_cnt <= 16'd0;
        else                      dma_active_cnt <= dma_active_cnt + 16'd1;
    end

    always_ff @(posedge clk) begin
        if (state == DONE)
            assert (dma_active_cnt < 16'd50000)
                else $error("[DMA %0t] timeout after %0d cycles",
                            $time, dma_active_cnt);
    end

`endif // SIMULATION

endmodule
