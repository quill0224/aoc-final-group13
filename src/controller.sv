`include "AXI/AXI_define.svh"
`include "ASIC.svh"

// =============================================================================
// controller.sv — Trapezoid-Lite ASIC FSM Controller
//
// MKN loop (outer→inner): M(spatial) → K(input ch×filter) → N(output ch)
// A reuse: loaded once per M tile, reused across all K×N iterations
// B: reloaded every N tile
//
// DMA_done contract: 1-cycle pulse; controller latches with sticky flags
// DMA re-trigger prevention: DMA_en deasserts once flag is set
// =============================================================================

module controller (
    // System
    input  logic                                clk,
    input  logic                                rst,
    input  logic                                asic_en,       // level, from AXI-Lite MMIO
    output logic                                asic_done,     // level, held until asic_en deasserts

    // DRAM Base Addresses
    input  logic [`AXI_ADDR_BITS-1:0]           A_fiber_base_addr,
    input  logic [`AXI_ADDR_BITS-1:0]           B_fiber_base_addr,
    input  logic [`AXI_ADDR_BITS-1:0]           C_tensor_base_addr,

    // GLB Base Addresses
    input  logic [`GLB_ADDR_BITS-1:0]           GLB_A_base_addr,
    input  logic [`GLB_ADDR_BITS-1:0]           GLB_B_base_addr,
    input  logic [`GLB_ADDR_BITS-1:0]           GLB_C_base_addr,

    // Tiling & Control (bytes, must be 4B-aligned)
    input  logic [31:0]                         comp_A_len_in,
    input  logic [31:0]                         comp_B_len_in,
    input  logic [31:0]                         comp_C_len_in,
    input  logic [`N_CNT_BITS-1:0]              N_tiles_in,
    input  logic [`K_CNT_BITS-1:0]              K_tiles_in,
    input  logic [`M_CNT_BITS-1:0]              M_tiles_in,
    input  logic [`PKT_CNT_BITS-1:0]            packet_count_in,
    input  logic [1:0]                          operation_mode_in,

    // PE Mapping Parameters
    input  logic [3:0]                          e,
    input  logic [2:0]                          p,
    input  logic [2:0]                          q,    // q[2] must be 0 (asserted)
    input  logic [2:0]                          r,    // reserved
    input  logic [2:0]                          t,    // reserved

    // DMA Interface
    output logic                                DMA_en,
    output logic [1:0]                          DMA_mode,
    output logic [`AXI_ADDR_BITS-1:0]           DMA_DRAM_ADDR,
    output logic [`GLB_ADDR_BITS-1:0]           DMA_GLB_ADDR,
    output logic [31:0]                         DMA_len,
    input  logic                                DMA_done,      // 1-cycle pulse

    // MC Interface
    output logic                                mc_start,      // 1-cycle pulse at S5
    output logic [1:0]                          mc_mode,
    output logic [`GLB_ADDR_BITS-1:0]           mc_glb_base_A,
    output logic [`GLB_ADDR_BITS-1:0]           mc_glb_base_B,
    output logic [`PKT_CNT_BITS-1:0]            mc_packet_count,
    input  logic                                k_done,

    // PE Array Interface
    output logic [1:0]                          global_mode,
    output logic                                global_flush,  // 1-cycle pulse at S7
    output logic [`PE_ARRAY_H*`PE_ARRAY_W-1:0]  PE_en,
    output logic [10:0]                         PE_config,    // [10:9]=mode [8:5]=e [4:2]=p [1:0]=q[1:0]
    input  logic                                PEA_A_ready,
    input  logic                                PEA_B_ready,

    // Scan Chain (tied off)
    output logic                                set_XID,
    output logic                                set_YID,
    output logic                                set_LN,
    output logic [`XID_BITS-1:0]                ifmap_XID_scan_in,
    output logic [`XID_BITS-1:0]                filter_XID_scan_in,
    output logic [`XID_BITS-1:0]                ipsum_XID_scan_in,
    output logic [`XID_BITS-1:0]                opsum_XID_scan_in,
    output logic [`YID_BITS-1:0]                ifmap_YID_scan_in,
    output logic [`YID_BITS-1:0]                filter_YID_scan_in,
    output logic [`YID_BITS-1:0]                ipsum_YID_scan_in,
    output logic [`YID_BITS-1:0]                opsum_YID_scan_in,
    output logic [`PE_ARRAY_H-2:0]              LN_config_in,

    // PPU Interface
    input  logic                                PEA_opsum_valid,  // routed to PPU directly
    output logic                                PEA_opsum_ready,
    output logic [`XID_BITS-1:0]                opsum_tag_X,
    output logic [`YID_BITS-1:0]                opsum_tag_Y,
    output logic                                relu_sel,
    output logic                                Maxpool_en,
    output logic                                Maxpool_init,
    input  logic                                ppu_done
);

    // =========================================================================
    // FSM States (13 states, 4-bit binary encoding)
    // Loop order after S8: S9_NK → S10_WB → S9b_M → S2/S11
    // Writeback uses current addr_acc_C, then S9b updates it (no off-by-one)
    // =========================================================================
    typedef enum logic [3:0] {
        S0_IDLE           = 4'd0,
        S1_SHADOW_LATCH   = 4'd1,
        S2_DMA_FETCH_A    = 4'd2,   // load A tile (M boundary only)
        S3_DMA_FETCH_B    = 4'd3,   // load B tile (every N tile)
        S4_SEND_PE_CONFIG = 4'd4,   // 1-cycle config broadcast
        S5_MC_DISPATCH    = 4'd5,   // 1-cycle mc_start pulse
        S6_WAIT_K_DONE    = 4'd6,
        S7_FLUSH          = 4'd7,   // 1-cycle global_flush pulse
        S8_WAIT_PPU       = 4'd8,
        S9_UPDATE_NK      = 4'd9,   // update n_cnt/k_cnt
        S10_DMA_WRITEBACK = 4'd10,  // write C tile to DRAM
        S9b_UPDATE_M      = 4'd11,  // update m_cnt and addr_acc after writeback
        S11_DONE          = 4'd12
    } state_t;

    state_t cs, ns;

    // =========================================================================
    // Shadow Registers (latched from MMIO at S1)
    // =========================================================================
    logic [31:0]               comp_A_len;
    logic [31:0]               comp_B_len;
    logic [31:0]               comp_C_len;
    logic [`N_CNT_BITS-1:0]    N_tiles;
    logic [`K_CNT_BITS-1:0]    K_tiles;
    logic [`M_CNT_BITS-1:0]    M_tiles;
    logic [`PKT_CNT_BITS-1:0]  packet_count;
    logic [1:0]                operation_mode;
    logic [`GLB_ADDR_BITS-1:0] GLB_A_base;
    logic [`GLB_ADDR_BITS-1:0] GLB_B_base;
    logic [`GLB_ADDR_BITS-1:0] GLB_C_base;

    // =========================================================================
    // MKN Tile Counters
    // =========================================================================
    logic [`N_CNT_BITS-1:0]  n_cnt;
    logic [`K_CNT_BITS-1:0]  k_cnt;
    logic [`M_CNT_BITS-1:0]  m_cnt;

    // =========================================================================
    // Address Accumulators (32-bit, wraps at 4GB)
    // A: updated in S9b (once per M tile)
    // B: updated in S9_NK (once per N tile), reset in S9b
    // C: updated in S9b after writeback
    // =========================================================================
    logic [31:0] addr_acc_A;
    logic [31:0] addr_acc_B;
    logic [31:0] addr_acc_C;

    // =========================================================================
    // DMA Done Sticky Flags
    // DMA_done is a 1-cycle pulse; flags prevent missed pulses when the
    // FSM must wait for another condition (e.g. PEA_ready) after DMA completes.
    // Set: when DMA_done arrives in the corresponding fetch state
    // Clear: when FSM leaves that state (using cs, not ns, for set-priority)
    // =========================================================================
    logic dma_a_done_flag;
    logic dma_b_done_flag;
    logic dma_wb_done_flag;

    always_ff @(posedge clk) begin
        if (rst || cs == S0_IDLE) begin
            dma_a_done_flag  <= 1'b0;
            dma_b_done_flag  <= 1'b0;
            dma_wb_done_flag <= 1'b0;
        end else begin
            // set-priority: if DMA_done arrives on the same cycle as clear, set wins
            if      (cs == S2_DMA_FETCH_A && DMA_done) dma_a_done_flag <= 1'b1;
            else if (cs == S3_DMA_FETCH_B)              dma_a_done_flag <= 1'b0;

            if      (cs == S3_DMA_FETCH_B && DMA_done) dma_b_done_flag <= 1'b1;
            else if (cs == S4_SEND_PE_CONFIG)           dma_b_done_flag <= 1'b0;

            if      (cs == S10_DMA_WRITEBACK && DMA_done) dma_wb_done_flag <= 1'b1;
            else if (cs == S9b_UPDATE_M)                  dma_wb_done_flag <= 1'b0;
        end
    end

    // =========================================================================
    // asic_en Two-Stage Synchronizer
    // (* async_reg *) prevents synthesis from merging these FFs
    // =========================================================================
    (* async_reg = "TRUE" *) logic asic_en_sync1;
    (* async_reg = "TRUE" *) logic asic_en_sync;

    always_ff @(posedge clk) begin
        if (rst) begin
            asic_en_sync1 <= 1'b0;
            asic_en_sync  <= 1'b0;
        end else begin
            asic_en_sync1 <= asic_en;
            asic_en_sync  <= asic_en_sync1;
        end
    end

    // =========================================================================
    // FSM State Register
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) cs <= S0_IDLE;
        else     cs <= ns;
    end

    // =========================================================================
    // FSM Next-State Logic (combinational)
    // =========================================================================
    always_comb begin
        ns = cs;
        case (cs)
            S0_IDLE: begin
                if (asic_en_sync) ns = S1_SHADOW_LATCH;
            end

            S1_SHADOW_LATCH: begin
                ns = S2_DMA_FETCH_A;
            end

            S2_DMA_FETCH_A: begin
                if (dma_a_done_flag) ns = S3_DMA_FETCH_B;
            end

            S3_DMA_FETCH_B: begin
                // dma_b_done_flag decouples DMA_done pulse from PEA_ready timing
                if (dma_b_done_flag && PEA_A_ready && PEA_B_ready)
                    ns = S4_SEND_PE_CONFIG;
            end

            S4_SEND_PE_CONFIG: begin
                // mc_* signals are stable this cycle; MC may pre-sample them
                ns = S5_MC_DISPATCH;
            end

            S5_MC_DISPATCH: begin
                // mc_start pulse; MC must latch on this cycle's rising edge
                ns = S6_WAIT_K_DONE;
            end

            S6_WAIT_K_DONE: begin
                if (k_done) ns = S7_FLUSH;
            end

            S7_FLUSH: begin
                // global_flush pulse; PE rows drain local buffers to PPU
                ns = S8_WAIT_PPU;
            end

            S8_WAIT_PPU: begin
                if (ppu_done) ns = S9_UPDATE_NK;
            end

            S9_UPDATE_NK: begin
                // n_cnt/k_cnt read here are pre-update values (FF not yet updated)
                if (n_cnt < N_tiles - 1) begin
                    ns = S3_DMA_FETCH_B;              // more N tiles
                end else if (k_cnt < K_tiles - 1) begin
                    ns = S3_DMA_FETCH_B;              // N exhausted, more K tiles
                end else begin
                    ns = S10_DMA_WRITEBACK;           // K×N exhausted, writeback
                end
            end

            S10_DMA_WRITEBACK: begin
                if (dma_wb_done_flag) ns = S9b_UPDATE_M;
            end

            S9b_UPDATE_M: begin
                // addr_acc updated here, after writeback completes
                if (m_cnt < M_tiles - 1) ns = S2_DMA_FETCH_A;
                else                      ns = S11_DONE;
            end

            S11_DONE: begin
                if (!asic_en_sync) ns = S0_IDLE;
            end

            default: ns = S0_IDLE;
        endcase
    end

    // =========================================================================
    // Datapath — Shadow Latch, Counter Updates, Address Accumulators
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst || cs == S0_IDLE) begin
            comp_A_len     <= 32'd0;
            comp_B_len     <= 32'd0;
            comp_C_len     <= 32'd0;
            N_tiles        <= {{(`N_CNT_BITS-1){1'b0}}, 1'b1};
            K_tiles        <= {{(`K_CNT_BITS-1){1'b0}}, 1'b1};
            M_tiles        <= {{(`M_CNT_BITS-1){1'b0}}, 1'b1};
            packet_count   <= {{(`PKT_CNT_BITS-1){1'b0}}, 1'b1};
            operation_mode <= 2'd0;
            GLB_A_base     <= {`GLB_ADDR_BITS{1'b0}};
            GLB_B_base     <= {`GLB_ADDR_BITS{1'b0}};
            GLB_C_base     <= {`GLB_ADDR_BITS{1'b0}};
            n_cnt          <= {`N_CNT_BITS{1'b0}};
            k_cnt          <= {`K_CNT_BITS{1'b0}};
            m_cnt          <= {`M_CNT_BITS{1'b0}};
            addr_acc_A     <= 32'd0;
            addr_acc_B     <= 32'd0;
            addr_acc_C     <= 32'd0;
        end else begin

            // S1: latch MMIO; clamp tile counts to ≥1 to prevent underflow
            if (cs == S1_SHADOW_LATCH) begin
                comp_A_len     <= comp_A_len_in;
                comp_B_len     <= comp_B_len_in;
                comp_C_len     <= comp_C_len_in;
                N_tiles        <= (N_tiles_in >= 1)      ? N_tiles_in
                                : {{(`N_CNT_BITS-1){1'b0}}, 1'b1};
                K_tiles        <= (K_tiles_in >= 1)      ? K_tiles_in
                                : {{(`K_CNT_BITS-1){1'b0}}, 1'b1};
                M_tiles        <= (M_tiles_in >= 1)      ? M_tiles_in
                                : {{(`M_CNT_BITS-1){1'b0}}, 1'b1};
                packet_count   <= (packet_count_in >= 1) ? packet_count_in
                                : {{(`PKT_CNT_BITS-1){1'b0}}, 1'b1};
                operation_mode <= operation_mode_in;
                GLB_A_base     <= GLB_A_base_addr;
                GLB_B_base     <= GLB_B_base_addr;
                GLB_C_base     <= GLB_C_base_addr;

            // S9_NK: advance B address and n/k counters
            // addr_acc_B always increments (B is never reused)
            // When k×n both exhaust, counters reset; addr_acc_B is zeroed in S9b
            end else if (cs == S9_UPDATE_NK) begin
                addr_acc_B <= addr_acc_B + comp_B_len;
                if (n_cnt < N_tiles - 1) begin
                    n_cnt <= n_cnt + 1;
                end else begin
                    n_cnt <= {`N_CNT_BITS{1'b0}};
                    if (k_cnt < K_tiles - 1) k_cnt <= k_cnt + 1;
                    else                      k_cnt <= {`K_CNT_BITS{1'b0}};
                end

            // S9b: update A/C addresses and M counter after writeback
            // addr_acc_B reset here begins next M tile's K×N loop from B offset 0
            end else if (cs == S9b_UPDATE_M) begin
                addr_acc_A <= addr_acc_A + comp_A_len;
                addr_acc_C <= addr_acc_C + comp_C_len;
                addr_acc_B <= 32'd0;
                m_cnt      <= m_cnt + 1;
            end

        end
    end

    // =========================================================================
    // Output Assignments
    // =========================================================================

    assign asic_done = (cs == S11_DONE);

    // DMA_en deasserts once the done flag is set, preventing DMA re-trigger
    assign DMA_en =
        (cs == S2_DMA_FETCH_A    && !dma_a_done_flag)  ||
        (cs == S3_DMA_FETCH_B    && !dma_b_done_flag)  ||
        (cs == S10_DMA_WRITEBACK && !dma_wb_done_flag);

    assign DMA_mode =
        (cs == S2_DMA_FETCH_A)    ? 2'd0 :
        (cs == S3_DMA_FETCH_B)    ? 2'd1 :
        (cs == S10_DMA_WRITEBACK) ? 2'd3 :
                                    2'd0;

    assign DMA_DRAM_ADDR =
        (cs == S2_DMA_FETCH_A)    ? (A_fiber_base_addr  + addr_acc_A) :
        (cs == S3_DMA_FETCH_B)    ? (B_fiber_base_addr  + addr_acc_B) :
        (cs == S10_DMA_WRITEBACK) ? (C_tensor_base_addr + addr_acc_C) :
                                    {`AXI_ADDR_BITS{1'b0}};

    assign DMA_GLB_ADDR =
        (cs == S2_DMA_FETCH_A)    ? GLB_A_base :
        (cs == S3_DMA_FETCH_B)    ? GLB_B_base :
        (cs == S10_DMA_WRITEBACK) ? GLB_C_base :
                                    {`GLB_ADDR_BITS{1'b0}};

    assign DMA_len =
        (cs == S2_DMA_FETCH_A)    ? comp_A_len :
        (cs == S3_DMA_FETCH_B)    ? comp_B_len :
        (cs == S10_DMA_WRITEBACK) ? comp_C_len :
                                    32'd0;

    // mc_* stable from S4; mc_start pulses only in S5
    assign mc_start        = (cs == S5_MC_DISPATCH);
    assign mc_mode         = operation_mode;
    assign mc_glb_base_A   = GLB_A_base;
    assign mc_glb_base_B   = GLB_B_base;
    assign mc_packet_count = packet_count;

    assign global_mode  = operation_mode;
    assign global_flush = (cs == S7_FLUSH);

    assign PE_en =
        (cs == S4_SEND_PE_CONFIG ||
         cs == S5_MC_DISPATCH    ||
         cs == S6_WAIT_K_DONE    ||
         cs == S7_FLUSH          ||
         cs == S8_WAIT_PPU)
        ? {(`PE_ARRAY_H * `PE_ARRAY_W){1'b1}}
        : {(`PE_ARRAY_H * `PE_ARRAY_W){1'b0}};

    assign PE_config = {operation_mode, e, p, q[1:0]};  // q[2] dropped, asserted below

    assign PEA_opsum_ready = (cs == S8_WAIT_PPU);
    assign opsum_tag_X     = {`XID_BITS{1'b0}};
    assign opsum_tag_Y     = {`YID_BITS{1'b0}};
    assign relu_sel        = operation_mode[0];
    assign Maxpool_en      = 1'b0;
    assign Maxpool_init    = 1'b0;

    assign set_XID            = 1'b0;
    assign set_YID            = 1'b0;
    assign set_LN             = 1'b0;
    assign ifmap_XID_scan_in  = {`XID_BITS{1'b0}};
    assign filter_XID_scan_in = {`XID_BITS{1'b0}};
    assign ipsum_XID_scan_in  = {`XID_BITS{1'b0}};
    assign opsum_XID_scan_in  = {`XID_BITS{1'b0}};
    assign ifmap_YID_scan_in  = {`YID_BITS{1'b0}};
    assign filter_YID_scan_in = {`YID_BITS{1'b0}};
    assign ipsum_YID_scan_in  = {`YID_BITS{1'b0}};
    assign opsum_YID_scan_in  = {`YID_BITS{1'b0}};
    assign LN_config_in       = {(`PE_ARRAY_H-1){1'b0}};

    // suppress lint warnings for unused inputs
    logic unused_ok;
    assign unused_ok = ^{r, t, PEA_opsum_valid};

    // =========================================================================
    // Simulation Assertions
    // =========================================================================
`ifdef SIMULATION

    // variable declarations must precede procedural blocks in SV
    logic [15:0] dma_b_watchdog;
    logic [15:0] pea_watchdog;
    logic        mc_start_prev;
    logic        flush_prev;
    logic        s2_entry;          // high on first cycle of S2 only

    assign s2_entry = (cs == S2_DMA_FETCH_A) && (ns != S2_DMA_FETCH_A);

    // S1: MMIO parameter checks
    always_ff @(posedge clk) begin
        if (cs == S1_SHADOW_LATCH) begin
            assert (N_tiles_in >= 1)
                else $error("[CTRL %0t] N_tiles_in=%0d < 1", $time, N_tiles_in);
            assert (K_tiles_in >= 1)
                else $error("[CTRL %0t] K_tiles_in=%0d < 1", $time, K_tiles_in);
            assert (M_tiles_in >= 1)
                else $error("[CTRL %0t] M_tiles_in=%0d < 1", $time, M_tiles_in);
            assert (packet_count_in >= 1)
                else $error("[CTRL %0t] packet_count_in=0", $time);
            assert (comp_A_len_in > 0 && comp_A_len_in[1:0] == 2'b00)
                else $error("[CTRL %0t] comp_A_len_in=0x%08X: zero or not 4B-aligned",
                            $time, comp_A_len_in);
            assert (comp_B_len_in > 0 && comp_B_len_in[1:0] == 2'b00)
                else $error("[CTRL %0t] comp_B_len_in=0x%08X: zero or not 4B-aligned",
                            $time, comp_B_len_in);
            assert (comp_C_len_in > 0 && comp_C_len_in[1:0] == 2'b00)
                else $error("[CTRL %0t] comp_C_len_in=0x%08X: zero or not 4B-aligned",
                            $time, comp_C_len_in);
            assert (operation_mode_in == `MODE_STD_IP || operation_mode_in == `MODE_TRIP)
                else $error("[CTRL %0t] operation_mode_in=2'b%02b reserved",
                            $time, operation_mode_in);
        end
    end

    // S4: q[2] must be 0 (dropped from PE_config)
    always_ff @(posedge clk) begin
        if (cs == S4_SEND_PE_CONFIG)
            assert (q[2] == 1'b0)
                else $error("[CTRL %0t] q[2]=1 silently dropped from PE_config", $time);
    end

    // S3: DMA completion watchdog
    always_ff @(posedge clk) begin
        if (rst || cs != S3_DMA_FETCH_B || dma_b_done_flag)
            dma_b_watchdog <= 16'd0;
        else begin
            dma_b_watchdog <= dma_b_watchdog + 16'd1;
            assert (dma_b_watchdog < 16'd10000)
                else $error("[CTRL %0t] S3 DMA timeout after %0d cycles",
                            $time, dma_b_watchdog);
        end
    end

    // S3: PEA ready watchdog (starts after DMA done)
    always_ff @(posedge clk) begin
        if (rst || cs != S3_DMA_FETCH_B || !dma_b_done_flag)
            pea_watchdog <= 16'd0;
        else if (!(PEA_A_ready && PEA_B_ready)) begin
            pea_watchdog <= pea_watchdog + 16'd1;
            assert (pea_watchdog < 16'd200)
                else $error("[CTRL %0t] PEA_ready timeout after %0d cycles post DMA",
                            $time, pea_watchdog);
        end
    end

    // S2 entry: addr_acc_B must be 0 at start of each M tile
    always_ff @(posedge clk) begin
        if (s2_entry)
            assert (addr_acc_B == 32'd0)
                else $error("[CTRL %0t] addr_acc_B=0x%08X at S2 entry; B rewind missed",
                            $time, addr_acc_B);
    end

    // mc_start must be exactly 1 cycle wide
    always_ff @(posedge clk) mc_start_prev <= mc_start;
    always_ff @(posedge clk) begin
        if (mc_start_prev && mc_start)
            $error("[CTRL %0t] mc_start held high for >1 cycle", $time);
    end

    // global_flush must be exactly 1 cycle wide
    always_ff @(posedge clk) flush_prev <= global_flush;
    always_ff @(posedge clk) begin
        if (flush_prev && global_flush)
            $error("[CTRL %0t] global_flush held high for >1 cycle", $time);
    end

`endif // SIMULATION

endmodule
