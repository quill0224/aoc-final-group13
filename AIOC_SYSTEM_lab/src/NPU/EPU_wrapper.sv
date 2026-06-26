// =============================================================================
// EPU_wrapper.sv -- AXI4 slave (S6 @ 0x0005_0000) wrapping the pe_array engine.
// =============================================================================
// AXI4-Lite-style register file (single-beat, AWLEN/ARLEN=0). Drives the
// pe_array sparse-GEMM engine over MMIO and latches dumped C columns for CPU
// readback. Slave-only (no master). axi_clk domain, no CDC. Reset active-low
// (ARESETn = ~axi_rst at top level).
//
// AXI widths from AXI_define.svh (IDS=8 ADDR=32 SIZE=3 DATA=32 STRB=4). LEN is
// [3:0] to match the S6 nets in top.sv (AWLEN_S6/ARLEN_S6 are hardcoded [3:0]
// there; the AXI fabric includes src/AXI_define.svh where AXI_LEN_BITS=4).
//
// FIRMWARE CONTRACT (prog4 drives this; the wrapper passes values verbatim):
//   Feed order per tile = all 16 A fibers (CFG_LENGTH[15]=0) then all 16 B
//   columns (CFG_LENGTH[15]=1), so pe_entry's per-side index counter resets
//   correctly. Each fiber is:
//     1. write CFG_LENGTH  ([15]=is_b, [4:0]=len 0..16)
//     2. write CFG_BITMASK (16-bit occupancy mask)
//     3. write CFG_PUSH    (poll STATUS.cfg_busy==0 before the next push)
//     4. repeat ceil(len/4) times: write DATA_NZ (4 NZ bytes LSB-first:
//        NZ0=[7:0],NZ1=[15:8],NZ2=[23:16],NZ3=[31:24]) then DATA_PUSH
//        (poll STATUS.data_busy==0 between pushes)
//   Then: poll STATUS.compute_done==1, and for each output column write
//   DUMP(addr) -> poll STATUS.result_valid==1 -> read RESULT0..15. The wrapper
//   HW-gates dump on compute_done and auto-clears result_valid on each DUMP, so
//   per-column polling is race-free without an explicit clear between columns.
// =============================================================================
`include "AXI_define.svh"

module EPU_wrapper (
    input                              ACLK,
    input                              ARESETn,    // active-low = ~axi_rst

    // Write Address
    input        [`AXI_IDS_BITS-1:0]   AWID_S6,
    input        [`AXI_ADDR_BITS-1:0]  AWADDR_S6,
    input        [3:0]                 AWLEN_S6,
    input        [`AXI_SIZE_BITS-1:0]  AWSIZE_S6,
    input        [1:0]                 AWBURST_S6,
    input                              AWVALID_S6,
    output logic                       AWREADY_S6,
    // Write Data
    input        [`AXI_DATA_BITS-1:0]  WDATA_S6,
    input        [`AXI_STRB_BITS-1:0]  WSTRB_S6,
    input                              WLAST_S6,
    input                              WVALID_S6,
    output logic                       WREADY_S6,
    // Write Response
    output logic [`AXI_IDS_BITS-1:0]   BID_S6,
    output logic [1:0]                 BRESP_S6,
    output logic                       BVALID_S6,
    input                              BREADY_S6,
    // Read Address
    input        [`AXI_IDS_BITS-1:0]   ARID_S6,
    input        [`AXI_ADDR_BITS-1:0]  ARADDR_S6,
    input        [3:0]                 ARLEN_S6,
    input        [`AXI_SIZE_BITS-1:0]  ARSIZE_S6,
    input        [1:0]                 ARBURST_S6,
    input                              ARVALID_S6,
    output logic                       ARREADY_S6,
    // Read Data
    output logic [`AXI_IDS_BITS-1:0]   RID_S6,
    output logic [`AXI_DATA_BITS-1:0]  RDATA_S6,
    output logic [1:0]                 RRESP_S6,
    output logic                       RLAST_S6,
    output logic                       RVALID_S6,
    input                              RREADY_S6
);

    import trapezoid_pkg::*;   // N_PE_ROW=16, ACC_W=32, LOCAL_BUF_AW=9

    // -------------------------------------------------------------------------
    // Register offsets (byte addr [7:0]; ADDR[31:16]==0x0005 decoded by fabric)
    // -------------------------------------------------------------------------
    localparam logic [7:0] OFF_CTRL        = 8'h00;   // W: [0]=mode [1]=first_pass [2]=clear_result
    localparam logic [7:0] OFF_STATUS      = 8'h04;   // R: status bits
    localparam logic [7:0] OFF_CFG_LENGTH  = 8'h08;   // W: [15]=is_b [4:0]=len
    localparam logic [7:0] OFF_CFG_BITMASK = 8'h0C;   // W: [15:0] mask
    localparam logic [7:0] OFF_CFG_PUSH    = 8'h10;   // W: pulse pe_cfg_valid
    localparam logic [7:0] OFF_DATA_NZ     = 8'h14;   // W: [31:0] 4 NZ bytes
    localparam logic [7:0] OFF_DATA_PUSH   = 8'h18;   // W: pulse pe_data_valid
    localparam logic [7:0] OFF_NBASE       = 8'h1C;   // W: [8:0] cur_n_base
    localparam logic [7:0] OFF_DUMP        = 8'h20;   // W: [8:0] dump_addr, pulse dump_en
    localparam logic [7:0] OFF_RESULT0     = 8'h40;   // R: .. 0x7C (16 regs)

    // =========================================================================
    // WRITE FSM (single-beat register slave; template = WDT_wrapper)
    // =========================================================================
    localparam logic [2:0] W_IDLE = 3'd0, W_AW = 3'd1, W_W = 3'd2,
                           W_DATA = 3'd3, W_RESP = 3'd4;
    logic [2:0] wcur, wnext;

    logic [`AXI_IDS_BITS-1:0]  lat_awid;
    logic [`AXI_ADDR_BITS-1:0] lat_waddr;
    logic [3:0]                lat_awlen;
    logic [`AXI_DATA_BITS-1:0] lat_wdata;
    logic                      lat_wlast;

    always_ff @(posedge ACLK or negedge ARESETn)
        if (!ARESETn) wcur <= W_IDLE; else wcur <= wnext;

    always_comb begin
        case (wcur)
            W_IDLE : wnext = AWVALID_S6 ? W_AW   : W_IDLE;
            W_AW   : wnext =              W_W;
            W_W    : wnext = WVALID_S6  ? W_DATA : W_W;
            W_DATA : wnext = lat_wlast  ? W_RESP : W_W;
            W_RESP : wnext = BREADY_S6  ? W_IDLE : W_RESP;
            default: wnext = W_IDLE;
        endcase
    end

    // AW latch (capture on AW handshake; clear in IDLE)
    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            lat_awid <= '0; lat_waddr <= '0; lat_awlen <= '0;
        end else if (wcur == W_IDLE) begin
            lat_awid <= '0; lat_waddr <= '0; lat_awlen <= '0;
        end else if (AWVALID_S6 && AWREADY_S6) begin
            lat_awid  <= AWID_S6;
            lat_waddr <= AWADDR_S6;
            lat_awlen <= AWLEN_S6;
        end
    end

    // W latch
    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            lat_wdata <= '0; lat_wlast <= 1'b0;
        end else if (wcur == W_IDLE) begin
            lat_wdata <= '0; lat_wlast <= 1'b0;
        end else if (WVALID_S6 && WREADY_S6) begin
            lat_wdata <= WDATA_S6;
            lat_wlast <= WLAST_S6;
        end
    end

    // reg_wr  : data-register loads (idempotent, last beat wins -> fine any beat)
    // push_wr : side-effecting pulses (CFG/DATA/DUMP/clear) fire only on the
    //           final write beat, so a burst (AWLEN>0) pulses once, not per-beat.
    //           Single-beat (AWLEN=0): lat_wlast is always 1, so push_wr==reg_wr.
    wire reg_wr     = (wcur == W_DATA);
    wire push_wr    = reg_wr && lat_wlast;
    wire ctrl_clear = push_wr && (lat_waddr[7:0] == OFF_CTRL) && lat_wdata[2];

    // =========================================================================
    // Register file + control to pe_array
    // =========================================================================
    logic                        mode_reg;
    logic                        fp_reg;
    logic [15:0]                 cfg_length_reg;
    logic [15:0]                 cfg_bitmask_reg;
    logic [31:0]                 data_nz_reg;
    logic [LOCAL_BUF_AW-1:0]     nbase_reg;
    logic [LOCAL_BUF_AW-1:0]     dump_addr_reg;

    logic cfg_req, data_req;   // ingress requests, held until pe handshake
    logic dump_req;            // armed by DUMP write -> 1-cycle dump_en next cycle
    logic dump_en_q;

    logic pe_cfg_ready, pe_data_ready, pe_compute_done;

    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            mode_reg        <= 1'b0;
            fp_reg          <= 1'b0;
            cfg_length_reg  <= 16'd0;
            cfg_bitmask_reg <= 16'd0;
            data_nz_reg     <= 32'd0;
            nbase_reg       <= '0;
            dump_addr_reg   <= '0;
            cfg_req         <= 1'b0;
            data_req        <= 1'b0;
            dump_req        <= 1'b0;
        end else begin
            dump_req <= 1'b0;   // default: self-clears (consumed into dump_en_q)

            // data-register loads (decode latched address)
            if (reg_wr) begin
                case (lat_waddr[7:0])
                    OFF_CTRL: begin
                        mode_reg <= lat_wdata[0];
                        fp_reg   <= lat_wdata[1];
                        // bit2 = clear_result handled in the result block
                    end
                    OFF_CFG_LENGTH : cfg_length_reg  <= lat_wdata[15:0];
                    OFF_CFG_BITMASK: cfg_bitmask_reg <= lat_wdata[15:0];
                    OFF_DATA_NZ    : data_nz_reg     <= lat_wdata;
                    OFF_NBASE      : nbase_reg       <= lat_wdata[LOCAL_BUF_AW-1:0];
                    OFF_DUMP       : dump_addr_reg   <= lat_wdata[LOCAL_BUF_AW-1:0];
                    default: ;
                endcase
            end

            // side-effecting pulses: only on the final beat
            if (push_wr) begin
                case (lat_waddr[7:0])
                    OFF_CFG_PUSH : cfg_req  <= 1'b1;
                    OFF_DATA_PUSH: data_req <= 1'b1;
                    OFF_DUMP     : dump_req <= 1'b1;
                    default: ;
                endcase
            end

            // clear ingress request once the engine consumes the beat
            // (set has priority by construction: a fresh push lands with the
            //  flag still 0, so the clear-if below is false that cycle)
            if (cfg_req  && pe_cfg_ready)  cfg_req  <= 1'b0;
            if (data_req && pe_data_ready) data_req <= 1'b0;
        end
    end

    // dump_en: 1-cycle pulse, gated by compute_done so dump_en can never
    // coincide with acc_en (local_buffer_row forbids that collision).
    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) dump_en_q <= 1'b0;
        else          dump_en_q <= dump_req & pe_compute_done;
    end

    // write-channel outputs (combinational, active-high)
    always_comb begin
        AWREADY_S6 = (wcur == W_AW);
        WREADY_S6  = (wcur == W_W);
        BVALID_S6  = (wcur == W_RESP);
        BID_S6     = (wcur == W_RESP) ? lat_awid : '0;
        BRESP_S6   = `AXI_RESP_OKAY;   // 2'b00
    end

    // =========================================================================
    // pe_array instantiation
    // =========================================================================
    logic                                  pe_tile_done;
    logic signed [N_PE_ROW-1:0][ACC_W-1:0] c_out;
    logic                                  c_valid;

    pe_array u_pe_array (
        .clk            (ACLK),
        .rst_n          (ARESETn),
        // ingress (hold valid until ready)
        .pe_cfg_valid   (cfg_req),
        .pe_cfg_ready   (pe_cfg_ready),
        .pe_cfg_length  (cfg_length_reg),
        .pe_cfg_bitmask (cfg_bitmask_reg),
        .pe_data_valid  (data_req),
        .pe_data_ready  (pe_data_ready),
        .pe_data_nzvalue(data_nz_reg),
        // ctrl
        .mode           (mode_reg),
        .first_pass     (fp_reg),
        .cur_n_base     (nbase_reg),
        .dump_en        (dump_en_q),
        .dump_addr      (dump_addr_reg),
        .pe_compute_done(pe_compute_done),
        .pe_tile_done   (pe_tile_done),
        // result
        .c_out          (c_out),
        .c_valid        (c_valid),
        // debug taps (unused at SoC level)
        .dbg_ent_bitmask(),
        .dbg_ent_nz     (),
        .dbg_ent_len    (),
        .dbg_ent_side   (),
        .dbg_ent_idx    (),
        .dbg_ent_valid  ()
    );

    // =========================================================================
    // Result latch + sticky status flags
    //   Capture 16x32 c_out on the 1-cycle c_valid pulse (c_out not held after).
    //   result_valid: set on c_valid; auto-cleared on DUMP (>=2 cycles before
    //   the new column's c_valid, so per-column polling is race-free) and on
    //   CTRL.clear_result. c_valid capture has priority if it ever collides.
    //   tile_done_seen: set on pe_tile_done pulse; cleared by clear_result.
    // =========================================================================
    logic [N_PE_ROW-1:0][ACC_W-1:0] result_reg;
    logic                           result_valid;
    logic                           tile_done_seen;
    integer ri;

    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            for (ri = 0; ri < N_PE_ROW; ri = ri + 1) result_reg[ri] <= '0;
            result_valid   <= 1'b0;
            tile_done_seen <= 1'b0;
        end else begin
            if (c_valid) begin
                for (ri = 0; ri < N_PE_ROW; ri = ri + 1) result_reg[ri] <= c_out[ri];
                result_valid <= 1'b1;
            end else if (ctrl_clear) begin
                for (ri = 0; ri < N_PE_ROW; ri = ri + 1) result_reg[ri] <= '0;
                result_valid <= 1'b0;
            end else if (dump_req) begin
                result_valid <= 1'b0;   // arm for the column about to be dumped
            end

            if (pe_tile_done)    tile_done_seen <= 1'b1;
            else if (ctrl_clear) tile_done_seen <= 1'b0;
        end
    end

    // =========================================================================
    // READ FSM (template = DRAM_FSM read return; RLAST on final beat)
    // =========================================================================
    localparam logic [1:0] R_IDLE = 2'd0, R_AR = 2'd1, R_DATA = 2'd2;
    logic [1:0] rcur, rnext;

    logic [`AXI_IDS_BITS-1:0]  lat_arid;
    logic [`AXI_ADDR_BITS-1:0] lat_raddr;
    logic [3:0]                lat_arlen;
    logic [3:0]                rbeat;

    always_ff @(posedge ACLK or negedge ARESETn)
        if (!ARESETn) rcur <= R_IDLE; else rcur <= rnext;

    always_comb begin
        case (rcur)
            R_IDLE : rnext = ARVALID_S6 ? R_AR : R_IDLE;
            R_AR   : rnext =              R_DATA;
            R_DATA : rnext = (RVALID_S6 && RREADY_S6 && RLAST_S6) ? R_IDLE : R_DATA;
            default: rnext = R_IDLE;
        endcase
    end

    // AR latch
    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            lat_arid <= '0; lat_raddr <= '0; lat_arlen <= '0;
        end else if (ARVALID_S6 && ARREADY_S6) begin
            lat_arid  <= ARID_S6;
            lat_raddr <= ARADDR_S6;
            lat_arlen <= ARLEN_S6;
        end
    end

    // read-beat counter for RLAST
    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn)                    rbeat <= 4'd0;
        else if (rcur == R_IDLE)         rbeat <= 4'd0;
        else if (RVALID_S6 && RREADY_S6) rbeat <= rbeat + 4'd1;
    end

    // status word
    logic [31:0] status_word;
    always_comb begin
        status_word    = 32'd0;
        status_word[0] = pe_cfg_ready;     // cfg_ready
        status_word[1] = pe_data_ready;    // data_ready
        status_word[2] = pe_compute_done;  // compute_done (level)
        status_word[3] = tile_done_seen;   // sticky
        status_word[4] = result_valid;     // sticky
        status_word[5] = cfg_req;          // cfg_busy
        status_word[6] = data_req;         // data_busy
    end

    // read data select (decode latched addr; config regs readable for bring-up)
    logic [31:0] rsel;
    always_comb begin
        if ((lat_raddr[7:0] >= OFF_RESULT0) &&
            (lat_raddr[7:0] <= (OFF_RESULT0 + 8'h3C)))
            rsel = result_reg[lat_raddr[5:2]];   // (addr-0x40)>>2, index 0..15
        else begin
            case (lat_raddr[7:0])
                OFF_STATUS     : rsel = status_word;
                OFF_CTRL       : rsel = {30'd0, fp_reg, mode_reg};
                OFF_CFG_LENGTH : rsel = {16'd0, cfg_length_reg};
                OFF_CFG_BITMASK: rsel = {16'd0, cfg_bitmask_reg};
                OFF_DATA_NZ    : rsel = data_nz_reg;
                OFF_NBASE      : rsel = {{(32-LOCAL_BUF_AW){1'b0}}, nbase_reg};
                OFF_DUMP       : rsel = {{(32-LOCAL_BUF_AW){1'b0}}, dump_addr_reg};
                default        : rsel = 32'd0;
            endcase
        end
    end

    // read-channel outputs
    always_comb begin
        ARREADY_S6 = (rcur == R_AR);
        RVALID_S6  = (rcur == R_DATA);
        RDATA_S6   = rsel;
        RID_S6     = lat_arid;
        RRESP_S6   = `AXI_RESP_OKAY;   // 2'b00
        RLAST_S6   = (rcur == R_DATA) && (rbeat == lat_arlen);
    end

endmodule
