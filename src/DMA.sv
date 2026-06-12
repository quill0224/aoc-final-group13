`include "AXI/AXI_define.svh"
`include "ASIC_define.svh"

// =============================================================================
// dma.sv — AXI4 Master DMA for Trapezoid-Lite ASIC
//
// 職責:
// 1. 處理 AXI4 Master 讀寫協定 (INCR burst)。
// 2. 自動將大於 1024 Bytes 的請求切割為多個 256-beats 的 Burst。
// 3. Fetch (DRAM->GLB) 採無 FIFO 直寫，達到 100% 頻寬。
// 4. Writeback (GLB->DRAM) 採 16-deep 同步 FIFO，完美吸收 AXI WREADY stall。
// =============================================================================

module dma (
    input  logic                      clk,
    input  logic                      rst_n,

    // -------------------------------------------------------------------------
    // Top Controller Interface
    // -------------------------------------------------------------------------
    input  logic                      DMA_en,
    input  logic [1:0]                DMA_mode, // 0/1: Fetch A/B, 3: Writeback C
    input  logic [`AXI_ADDR_BITS-1:0] DMA_DRAM_ADDR,
    input  logic [`GLB_ADDR_BITS-1:0] DMA_GLB_ADDR,
    input  logic [31:0]               DMA_len,  // 傳輸總位元組數 (Bytes)
    output logic                      DMA_done,

    // -------------------------------------------------------------------------
    // GLB Master Interface
    // -------------------------------------------------------------------------
    output logic                      glb_en,
    output logic                      glb_we,
    output logic [3:0]                glb_wstrb,
    output logic [`GLB_ADDR_BITS-1:0] glb_addr,
    output logic [31:0]               glb_wdata,
    input  logic [31:0]               glb_rdata,

    // -------------------------------------------------------------------------
    // AXI4 Master Interface
    // -------------------------------------------------------------------------
    // AR Channel (Read Address)
    output logic [`AXI_ID_BITS-1:0]   ARID,
    output logic [`AXI_ADDR_BITS-1:0] ARADDR,
    output logic [`AXI_LEN_BITS-1:0]  ARLEN,
    output logic [`AXI_SIZE_BITS-1:0] ARSIZE,
    output logic [1:0]                ARBURST,
    output logic                      ARVALID,
    input  logic                      ARREADY,
    
    // R Channel (Read Data)
    input  logic [`AXI_ID_BITS-1:0]   RID,
    input  logic [`AXI_DATA_BITS-1:0] RDATA,
    input  logic [1:0]                RRESP,
    input  logic                      RLAST,
    input  logic                      RVALID,
    output logic                      RREADY,
    
    // AW Channel (Write Address)
    output logic [`AXI_ID_BITS-1:0]   AWID,
    output logic [`AXI_ADDR_BITS-1:0] AWADDR,
    output logic [`AXI_LEN_BITS-1:0]  AWLEN,
    output logic [`AXI_SIZE_BITS-1:0] AWSIZE,
    output logic [1:0]                AWBURST,
    output logic                      AWVALID,
    input  logic                      AWREADY,
    
    // W Channel (Write Data)
    output logic [`AXI_DATA_BITS-1:0] WDATA,
    output logic [`AXI_STRB_BITS-1:0] WSTRB,
    output logic                      WLAST,
    output logic                      WVALID,
    input  logic                      WREADY,
    
    // B Channel (Write Response)
    input  logic [`AXI_ID_BITS-1:0]   BID,
    input  logic [1:0]                BRESP,
    input  logic                      BVALID,
    output logic                      BREADY
);

    // =========================================================================
    // FSM States
    // =========================================================================
    typedef enum logic [2:0] {
        IDLE      = 3'd0,
        REQ_AR    = 3'd1, // 發送 AXI Read 位址
        FETCH_R   = 3'd2, // 接收 AXI Data 並寫入 GLB
        REQ_AW    = 3'd3, // 發送 AXI Write 位址
        WB_FILL   = 3'd4, // 預先讀取 GLB 填入 FIFO
        WB_W      = 3'd5, // 發送 AXI Write Data
        WB_B      = 3'd6, // 等待 AXI Write Response
        DONE      = 3'd7
    } dma_state_t;

    dma_state_t state, next_state;

    // =========================================================================
    // Internal Registers & Chunking Logic
    // =========================================================================
    logic [31:0] rem_bytes;       // 尚未傳輸的剩餘 Bytes
    logic [31:0] cur_dram_addr;
    logic [31:0] cur_glb_addr;
    
    logic [31:0] burst_bytes;     // 當前 Burst 的 Bytes (最大 1024)
    logic [7:0]  burst_beats_m1;  // 當前 Burst 的 ARLEN/AWLEN (Beats - 1)
    logic [8:0]  beats_transferred; // 已傳輸的 Beats 數計數器

    // 自動切割：若剩餘 Bytes 大於 1024，則本次 Burst 傳輸 1024 Bytes
    assign burst_bytes    = (rem_bytes > 32'd1024) ? 32'd1024 : rem_bytes;
    assign burst_beats_m1 = (burst_bytes[11:2]) - 8'd1; // 除以 4 再減 1

    // =========================================================================
    // FIFO Logic for Writeback (GLB -> DRAM)
    // 解決 GLB 1-cycle latency 與 AXI WREADY 停滯的時序問題
    // =========================================================================
    logic [31:0] fifo [0:15];
    logic [4:0]  fifo_cnt;
    logic [3:0]  wr_ptr, rd_ptr;
    
    logic        glb_rd_req;
    logic        glb_rd_valid; // 延遲一拍的讀取有效訊號

    // GLB 讀取請求邏輯 (當 FIFO 有空間且尚未讀完當前 Burst 時發動)
    assign glb_rd_req = ((state == WB_FILL) || (state == WB_W)) && 
                        (fifo_cnt + glb_rd_valid < 5'd15) && // 預留 1 格給 inflight 資料
                        (beats_transferred < (burst_beats_m1 + 1));

    // 追蹤 GLB 讀取的 In-flight 狀態 (1 cycle latency)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) glb_rd_valid <= 1'b0;
        else        glb_rd_valid <= glb_rd_req;
    end

    // FIFO 寫入 (Push: 來自 GLB) 與 讀出 (Pop: 去往 AXI)
    logic fifo_push, fifo_pop;
    assign fifo_push = glb_rd_valid;
    assign fifo_pop  = (state == WB_W) && WVALID && WREADY;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_cnt <= 5'd0;
            wr_ptr   <= 4'd0;
            rd_ptr   <= 4'd0;
        end else if (state == IDLE || state == REQ_AW) begin
            // 每次 Burst 前清空 FIFO 指標
            fifo_cnt <= 5'd0;
            wr_ptr   <= 4'd0;
            rd_ptr   <= 4'd0;
        end else begin
            if (fifo_push && !fifo_pop)      fifo_cnt <= fifo_cnt + 5'd1;
            else if (!fifo_push && fifo_pop) fifo_cnt <= fifo_cnt - 5'd1;

            if (fifo_push) begin
                fifo[wr_ptr] <= glb_rdata;
                wr_ptr       <= wr_ptr + 4'd1;
            end
            if (fifo_pop) begin
                rd_ptr <= rd_ptr + 4'd1;
            end
        end
    end

    // =========================================================================
    // FSM Logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end

    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                if (DMA_en) begin
                    if (DMA_mode == 2'd3) next_state = REQ_AW; // Writeback C
                    else                  next_state = REQ_AR; // Fetch A/B
                end
            end

            // --- Read Path (DRAM -> GLB) ---
            REQ_AR: begin
                if (ARVALID && ARREADY) next_state = FETCH_R;
            end
            FETCH_R: begin
                if (RVALID && RREADY && RLAST) begin
                    if (rem_bytes == burst_bytes) next_state = DONE;
                    else                          next_state = REQ_AR; // 繼續下一個 Chunk
                end
            end

            // --- Write Path (GLB -> DRAM) ---
            REQ_AW: begin
                if (AWVALID && AWREADY) next_state = WB_FILL;
            end
            WB_FILL: begin
                // 預填 FIFO，確保 AXI W channel 不會有 Bubble
                if (fifo_cnt >= 5'd2 || beats_transferred == (burst_beats_m1 + 1)) 
                    next_state = WB_W;
            end
            WB_W: begin
                if (WVALID && WREADY && WLAST) next_state = WB_B;
            end
            WB_B: begin
                if (BVALID && BREADY) begin
                    if (rem_bytes == burst_bytes) next_state = DONE;
                    else                          next_state = REQ_AW; // 繼續下一個 Chunk
                end
            end

            DONE: begin
                next_state = IDLE;
            end
            default: next_state = IDLE;
        endcase
    end

    // =========================================================================
    // Datapath & Address Counters
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rem_bytes         <= 32'd0;
            cur_dram_addr     <= 32'd0;
            cur_glb_addr      <= 32'd0;
            beats_transferred <= 9'd0;
        end else begin
            if (state == IDLE && DMA_en) begin
                // 鎖存初始設定
                rem_bytes     <= DMA_len;
                cur_dram_addr <= DMA_DRAM_ADDR;
                cur_glb_addr  <= DMA_GLB_ADDR;
            end 
            else if (state == REQ_AR || state == REQ_AW) begin
                beats_transferred <= 9'd0;
            end
            else if (state == FETCH_R) begin
                if (RVALID && RREADY) begin
                    cur_glb_addr  <= cur_glb_addr + 32'd4;
                    cur_dram_addr <= cur_dram_addr + 32'd4;
                    if (RLAST) rem_bytes <= rem_bytes - burst_bytes;
                end
            end
            else if (state == WB_W || state == WB_FILL) begin
                // GLB 讀取位址推進
                if (glb_rd_req) begin
                    cur_glb_addr      <= cur_glb_addr + 32'd4;
                    beats_transferred <= beats_transferred + 9'd1;
                end
                // AXI 位址推進在 B_WAIT 完成時結算
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

    // GLB Interface
    // Fetch 階段：直接將 RVALID 映射為 glb_we；Writeback 階段：由 glb_rd_req 觸發讀取
    assign glb_we    = (state == FETCH_R) && RVALID && RREADY;
    assign glb_en    = glb_we || glb_rd_req;
    assign glb_wstrb = 4'b1111; // DMA 一律整 Word 讀寫
    assign glb_wdata = RDATA;
    assign glb_addr  = cur_glb_addr[`GLB_ADDR_BITS-1:0];

    // AXI AR Channel (Read)
    assign ARID    = `AXI_ID_BITS'd2;
    assign ARADDR  = cur_dram_addr;
    assign ARLEN   = burst_beats_m1;
    assign ARSIZE  = 3'b010; // 4 Bytes per beat
    assign ARBURST = 2'b01;  // INCR mode
    assign ARVALID = (state == REQ_AR);
    
    // AXI R Channel
    assign RREADY  = (state == FETCH_R); // 由於 GLB 隨時可寫，直接無條件 Ready

    // AXI AW Channel (Write)
    assign AWID    = `AXI_ID_BITS'd2;
    assign AWADDR  = cur_dram_addr;
    assign AWLEN   = burst_beats_m1;
    assign AWSIZE  = 3'b010; // 4 Bytes per beat
    assign AWBURST = 2'b01;  // INCR mode
    assign AWVALID = (state == REQ_AW);

    // AXI W Channel
    assign WDATA   = fifo[rd_ptr];
    assign WSTRB   = 4'b1111;
    assign WVALID  = (state == WB_W) && (fifo_cnt > 5'd0);
    // 當前送出的 WDATA 若是這回合 Burst 的最後一筆，拉高 WLAST
    logic [8:0] w_beats_sent;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) w_beats_sent <= 9'd0;
        else if (state == REQ_AW) w_beats_sent <= 9'd0;
        else if (WVALID && WREADY) w_beats_sent <= w_beats_sent + 9'd1;
    end
    assign WLAST   = (state == WB_W) && (w_beats_sent == burst_beats_m1);

    // AXI B Channel
    assign BREADY  = (state == WB_B);

endmodule
