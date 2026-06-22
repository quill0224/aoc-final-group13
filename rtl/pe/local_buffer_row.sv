// =============================================================================
// local_buffer_row.sv — per-PE-row output accumulation buffer (4-bank, SRAM-based)
// =============================================================================
// Function:
//   Stores the C partial sums for all output columns n of one PE row (fixed m).
//   Capacity 512 columns x INT32 (4 banks x 128 x 32-bit). Accepts up to 4 write
//   requests per cycle (sum + column address), routed to the matching bank:
//     first_pass=1 -> overwrite (first K segment of the column; effectively clears, no read)
//     first_pass=0 -> accumulate (read-modify-write: read old value + sum, write back)
//   Also provides a dump interface to read out a single column's final value (for GLB write-back).
//   Dump is read-and-CLEAR: the dumped address is written 0 one cycle after the read
//   (read on the read port at T, clear on the write port at T+1 -> macro-safe), so the
//   next output block (M-tile) starts from a clean 0 buffer (no cross-tile residue).
//
// Address mapping:
//   column address addr[8:0] -> bank = addr[1:0], in-bank offset = addr[8:2].
//   Multiple requests in one cycle hitting distinct banks are written in parallel.
//
// Interface:
//   clk / rst_n / en         clock; async reset (active-low); pipeline enable
//   wr_valid   [4]      in   per-lane request present this cycle
//   wr_sum     [4][32]  in   per-lane partial sum (signed)
//   wr_addr    [4][9]   in   per-lane column address
//   first_pass          in   1 = overwrite; 0 = RMW accumulate
//   acc_en              in   wr_* valid this cycle (same cycle as upstream data valid)
//   dump_en / dump_addr in   read-out request / column address
//   c_valid             out  dump result valid (2 cycles after dump_en)
//   c_out      [32]     out  dump result (signed)
//
// Timing:
//   Accumulate RMW = 2-cycle pipeline: cycle T issues read, cycle T+1 writes back "old + sum";
//   a new request can be accepted every cycle (fully pipelined).
//   Two back-to-back writes to the same column: SRAM read value is not yet updated
//   (1-cycle read latency) -> write-forward bypass uses the previous cycle's written value,
//   so the result is still correct.
//   dump: dump_en at cycle T -> c_valid / c_out valid at cycle T+2.
//
// Assumptions and constraints:
//   - Valid requests in one cycle must hit distinct banks (wr_addr[1:0] distinct);
//     same-bank conflicts are not serialized (checked by sim-time assertion). Upstream pe_row
//     compresses the tree's 16-lane output into <=4 requests meeting this condition.
//   - dump_en must not coincide with acc_en (shared read port).
//   - ACC_W = 32, aligned to bank (128x32 SRAM) data width.
//
// Datapath location:
//   Upstream: pe_row's 16->4 compression layer feeds <=4 banked write requests (wr_*),
//        acc_en aligned with tree output valid; first_pass / dump_* driven by dataflow
//        control logic (delay-aligned through pe_row).
//   This stage: S8 (output accumulation) of pe_row_full.
//   Downstream: c_out -> GLB write-back path.
//   bank is a sram_128x32_1r1w wrapper; define USE_SRAM_MACRO at synthesis to hook the real macro.
// =============================================================================

module local_buffer_row
    import trapezoid_pkg::*;
(
    input  logic                                            clk,
    input  logic                                            rst_n,
    input  logic                                            en,

    // ── Up to 4 banked write requests (upstream already compressed to ≤4, distinct banks) ──
    input  logic        [N_BANK_LBUF-1:0]                   wr_valid,
    input  logic signed [N_BANK_LBUF-1:0][ACC_W-1:0]        wr_sum,
    input  logic        [N_BANK_LBUF-1:0][LOCAL_BUF_AW-1:0] wr_addr,
    input  logic                                            first_pass, // first K segment: overwrite
    input  logic                                            acc_en,

    // ── dump (must not occur in the same cycle as acc_en) ──
    input  logic                                            dump_en,
    input  logic        [LOCAL_BUF_AW-1:0]                  dump_addr,
    output logic                                            c_valid,
    output logic signed [ACC_W-1:0]                         c_out
);

    localparam int NB   = N_BANK_LBUF;        // 4
    localparam int OFFW = LOCAL_BUF_AW - 2;   // 7 (128 deep/bank)

    // ── Layer 0: unpack inputs + pre-decode bank/offset (avoids iverilog's limit on
    //    bit-selecting a variable-indexed element inside always; split out via generate-assign) ──
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

    // ── Layer 1+2: route each request to its corresponding bank ──
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

    // dump decode
    logic [1:0]      dump_bank;
    logic [OFFW-1:0] dump_off;
    assign dump_bank = dump_addr[1:0];
    assign dump_off  = dump_addr[LOCAL_BUF_AW-1:2];

    // ── per-bank SRAM interface wires ──
    logic            bk_ren   [NB];
    logic [OFFW-1:0] bk_raddr [NB];
    logic [31:0]     bk_rdata [NB];
    logic            bk_wen   [NB];
    logic [OFFW-1:0] bk_waddr [NB];
    logic [31:0]     bk_wdata [NB];

    // ── Stage-1 registers ──
    logic                    s1_v    [NB];
    logic signed [ACC_W-1:0] s1_sum  [NB];
    logic [OFFW-1:0]         s1_off  [NB];
    logic                    s1_first;
    logic                    dump_pend;
    logic [1:0]              dump_bank_q;
    logic [OFFW-1:0]         dump_off_q;   // clear-on-dump:記住要清 0 的 offset

    // RMW bypass: remember what each bank wrote last cycle, for back-to-back same-address accumulation (classifier N=1)
    logic             prev_wen   [NB];
    logic [OFFW-1:0]  prev_waddr [NB];
    logic [ACC_W-1:0] prev_wdata [NB];

    // ── Stage 0: issue READ (RMW read for acc, or dump read) ──
    always_comb begin
        for (int b = 0; b < NB; b = b + 1) begin
            bk_ren[b]   = 1'b0;
            bk_raddr[b] = '0;
        end
        if (en && acc_en && !first_pass) begin
            // RMW: each bank with a request reads its old value first
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

    // ── Latch request / dump into Stage 1 ──
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
                prev_wen[b]   <= bk_wen[b];     // remember this cycle's write for next-cycle bypass
                prev_waddr[b] <= bk_waddr[b];
                prev_wdata[b] <= bk_wdata[b];
            end
            s1_first    <= first_pass;
            dump_pend   <= dump_en;
            dump_bank_q <= dump_bank;
            dump_off_q  <= dump_off;
            // dump output: read has 1-cycle latency → register one more cycle here
            c_valid <= dump_pend;
            c_out   <= $signed(bk_rdata[dump_bank_q]);
        end
    end

    // ── Stage 1: compute write data, drive bank write-back (incl. RMW bypass) ──
    logic signed [ACC_W-1:0] rd_val [NB];
    always_comb begin
        for (int b = 0; b < NB; b = b + 1) begin
            // RMW bypass: if this cycle's read offset == last cycle's written offset, the SRAM is not
            // updated yet (1-cycle read latency) → use last cycle's written value (classifier N=1 back-to-back accum hits this)
            if (prev_wen[b] && (s1_off[b] == prev_waddr[b]))
                rd_val[b] = $signed(prev_wdata[b]);
            else
                rd_val[b] = $signed(bk_rdata[b]);

            bk_wen[b]   = en & s1_v[b];
            bk_waddr[b] = s1_off[b];
            if (s1_first)
                bk_wdata[b] = s1_sum[b];               // overwrite (first_pass)
            else
                bk_wdata[b] = rd_val[b] + s1_sum[b];   // accumulate (RMW, incl. bypass)

            // clear-on-dump:dump 讀出的下一拍把該位址寫 0(讀已在前一拍鎖進 c_out,
            // 不影響輸出),讓下一個 M-tile 從乾淨的 0 開始,避免跨 M-tile 殘值。
            // 讀在 T(讀埠)、清在 T+1(寫埠)→ 非同拍同址,macro 也安全。
            // dump 與 acc 不同拍(上層保證),故覆寫該 bank 寫埠安全。
            if (dump_pend && (dump_bank_q == 2'(b))) begin
                bk_wen[b]   = en;
                bk_waddr[b] = dump_off_q;
                bk_wdata[b] = '0;
            end
        end
    end

    // ── 4 SRAM banks ──
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

    // ── Design-assumption checks (skipped in synthesis) ──
    // synthesis translate_off
    // This block is a sim-only assertion; here rst_n only gates as a sync condition (not a real reset).
    // Combined with the other flops' async rst_n it triggers verilator SYNCASYNCNET, so disable it locally.
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
