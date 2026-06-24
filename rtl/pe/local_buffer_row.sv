// =============================================================================
// local_buffer_row.sv - per-row partial-sum buffer
// =============================================================================
// Stores 512 signed 32-bit partial sums in four 128-word SRAM banks.
// Address bits [1:0] select the bank and the remaining bits select the row.
//
// first_pass=1 overwrites the addressed entries. first_pass=0 performs a
// pipelined read-modify-write accumulation. A one-entry write-forward path per
// bank handles back-to-back updates to the same address.
//
// dump_en reads one entry and clears it on the following cycle. c_valid and
// c_out are produced two cycles after dump_en.
//
// Constraints:
//   - Write requests in the same cycle must target different banks.
//   - dump_en and acc_en must not be asserted together.
// =============================================================================

module local_buffer_row
    import trapezoid_pkg::*;
(
    input  logic                                            clk,
    input  logic                                            rst_n,
    input  logic                                            en,

    // Up to four write requests
    input  logic        [N_BANK_LBUF-1:0]                   wr_valid,
    input  logic signed [N_BANK_LBUF-1:0][ACC_W-1:0]        wr_sum,
    input  logic        [N_BANK_LBUF-1:0][LOCAL_BUF_AW-1:0] wr_addr,
    input  logic                                            first_pass, // overwrite instead of accumulate
    input  logic                                            acc_en,

    // Read-and-clear interface
    input  logic                                            dump_en,
    input  logic        [LOCAL_BUF_AW-1:0]                  dump_addr,
    output logic                                            c_valid,
    output logic signed [ACC_W-1:0]                         c_out
);

    localparam int NB   = N_BANK_LBUF;        // 4
    localparam int OFFW = LOCAL_BUF_AW - 2;   // 7 (128 deep/bank)

    // Unpack requests and decode bank/offset.
    logic                    wv_u    [NB];
    logic signed [ACC_W-1:0] ws_u    [NB];
    logic [1:0]              wbank_u [NB];
    logic [OFFW-1:0]         woff_u  [NB];
    genvar gi;
    generate
        for (gi = 0; gi < NB; gi = gi + 1) begin : g_unpack
            assign wv_u[gi]    = wr_valid[gi];
            assign ws_u[gi]    = wr_sum[gi];
            assign wbank_u[gi] = wr_addr[gi][1:0];               // bank = addr[1:0]
            assign woff_u[gi]  = wr_addr[gi][LOCAL_BUF_AW-1:2];  // offset = addr high bits
        end
    endgenerate

    // Route each request to its selected bank.
    logic                    req_v   [NB];
    logic signed [ACC_W-1:0] req_sum [NB];
    logic [OFFW-1:0]         req_off [NB];
    genvar gb;
    generate
        for (gb = 0; gb < NB; gb = gb + 1) begin : g_route
            always_comb begin
                req_v[gb]   = 1'b0;
                req_sum[gb] = '0;
                req_off[gb] = '0;
                for (int k = 0; k < NB; k = k + 1) begin
                    if (wv_u[k] && (wbank_u[k] == gb[1:0])) begin
                        req_v[gb]   = 1'b1;
                        req_sum[gb] = ws_u[k];
                        req_off[gb] = woff_u[k];
                    end
                end
            end
        end
    endgenerate

    // Dump address decode
    logic [1:0]      dump_bank;
    logic [OFFW-1:0] dump_off;
    assign dump_bank = dump_addr[1:0];
    assign dump_off  = dump_addr[LOCAL_BUF_AW-1:2];

    // SRAM interfaces
    logic            bk_ren   [NB];
    logic [OFFW-1:0] bk_raddr [NB];
    logic [31:0]     bk_rdata [NB];
    logic            bk_wen   [NB];
    logic [OFFW-1:0] bk_waddr [NB];
    logic [31:0]     bk_wdata [NB];

    // Request pipeline registers
    logic                    s1_v    [NB];
    logic signed [ACC_W-1:0] s1_sum  [NB];
    logic [OFFW-1:0]         s1_off  [NB];
    logic                    s1_first;
    logic                    dump_pend;
    logic [1:0]              dump_bank_q;
    logic [OFFW-1:0]         dump_off_q;

    // Last write per bank for read-after-write forwarding.
    logic             prev_wen   [NB];
    logic [OFFW-1:0]  prev_waddr [NB];
    logic [ACC_W-1:0] prev_wdata [NB];

    // Issue an accumulation or dump read.
    always_comb begin
        for (int b = 0; b < NB; b = b + 1) begin
            bk_ren[b]   = 1'b0;
            bk_raddr[b] = '0;
        end
        if (en && acc_en && !first_pass) begin
            // Read the previous partial sum for each active bank.
            for (int b = 0; b < NB; b = b + 1) begin
                if (req_v[b]) begin
                    bk_ren[b]   = 1'b1;
                    bk_raddr[b] = req_off[b];
                end
            end
        end else if (en && dump_en) begin
            bk_ren[dump_bank]   = 1'b1;
            bk_raddr[dump_bank] = dump_off;
        end
    end

    // Latch the request while SRAM read data is produced.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int b = 0; b < NB; b = b + 1) begin
                s1_v[b]       <= 1'b0;
                s1_sum[b]     <= '0;
                s1_off[b]     <= '0;
                prev_wen[b]   <= 1'b0;
                prev_waddr[b] <= '0;
                prev_wdata[b] <= '0;
            end
            s1_first    <= 1'b0;
            dump_pend   <= 1'b0;
            dump_bank_q <= '0;
            dump_off_q  <= '0;
            c_valid     <= 1'b0;
            c_out       <= '0;
        end else if (en) begin
            for (int b = 0; b < NB; b = b + 1) begin
                s1_v[b]       <= acc_en & req_v[b];
                s1_sum[b]     <= req_sum[b];
                s1_off[b]     <= req_off[b];
                prev_wen[b]   <= bk_wen[b];
                prev_waddr[b] <= bk_waddr[b];
                prev_wdata[b] <= bk_wdata[b];
            end
            s1_first    <= first_pass;
            dump_pend   <= dump_en;
            dump_bank_q <= dump_bank;
            dump_off_q  <= dump_off;
            // Register the synchronous SRAM dump result.
            c_valid <= dump_pend;
            c_out   <= $signed(bk_rdata[dump_bank_q]);
        end
    end

    // Compute accumulation results and drive writes.
    logic signed [ACC_W-1:0] rd_val [NB];
    always_comb begin
        for (int b = 0; b < NB; b = b + 1) begin
            // Forward the previous write when the SRAM read would return stale data.
            if (prev_wen[b] && (s1_off[b] == prev_waddr[b]))
                rd_val[b] = $signed(prev_wdata[b]);
            else
                rd_val[b] = $signed(bk_rdata[b]);

            bk_wen[b]   = en & s1_v[b];
            bk_waddr[b] = s1_off[b];
            if (s1_first)
                bk_wdata[b] = s1_sum[b];
            else
                bk_wdata[b] = rd_val[b] + s1_sum[b];

            // Clear the dumped entry after its read data has been captured.
            if (dump_pend && (dump_bank_q == 2'(b))) begin
                bk_wen[b]   = en;
                bk_waddr[b] = dump_off_q;
                bk_wdata[b] = '0;
            end
        end
    end

    // Four SRAM banks
    generate
        for (gb = 0; gb < NB; gb = gb + 1) begin : g_bank
            sram_128x32_1r1w u_bank (
                .clk   (clk),
                .ren   (bk_ren[gb]),
                .raddr (bk_raddr[gb]),
                .rdata (bk_rdata[gb]),
                .wen   (bk_wen[gb]),
                .waddr (bk_waddr[gb]),
                .wdata (bk_wdata[gb])
            );
        end
    endgenerate

    // Simulation-only interface checks
    // synthesis translate_off
    // rst_n is sampled here only to gate the checks.
    /* verilator lint_off SYNCASYNCNET */
    always @(posedge clk) if (rst_n && en && acc_en) begin
        for (int ai = 0; ai < NB; ai = ai + 1)
            for (int aj = ai + 1; aj < NB; aj = aj + 1)
                if (wv_u[ai] && wv_u[aj] && (wbank_u[ai] == wbank_u[aj]))
                    $display("[ASSERT-FAIL] %0t: lanes %0d,%0d hit the same bank %0d in one cycle",
                             $time, ai, aj, wbank_u[ai]);
        if (dump_en)
            $display("[ASSERT-FAIL] %0t: dump_en must not coincide with acc_en", $time);
    end
    /* verilator lint_on SYNCASYNCNET */
    // synthesis translate_on

endmodule
