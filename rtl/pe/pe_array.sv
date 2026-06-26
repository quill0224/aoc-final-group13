// =============================================================================
// pe_array.sv - 16-row PE engine
// =============================================================================
//   pe_entry -> pe_ab_buffer -> 16 x pe_row
//
// The input stream contains 16 A fibers followed by 16 B fibers. A fiber r is
// assigned to PE row r; all rows share the B fibers. Writing B entry 15 starts
// all rows.
//
// Per-row done pulses are latched and combined. pe_compute_done is delayed by
// DRAIN cycles so the MAC, reduction, and accumulation pipeline can finish.
// pe_tile_done is a one-cycle pulse for controller sequencing.
//
// During dump, all rows read the same column address. c_out contains that
// column across 16 output rows.
// =============================================================================

module pe_array
    import trapezoid_pkg::*;
(
    input  logic                                clk,
    input  logic                                rst_n,

    // Compressed-fiber input stream
    input  logic                                pe_cfg_valid,
    output logic                                pe_cfg_ready,
    input  logic [15:0]                         pe_cfg_length,    // [15]=is_b, [4:0]=len
    input  logic [15:0]                         pe_cfg_bitmask,
    input  logic                                pe_data_valid,
    output logic                                pe_data_ready,
    input  logic [31:0]                         pe_data_nzvalue,

    // Control
    input  logic                                mode,             // 1=TrIP
    input  logic                                first_pass,       // overwrite the first K tile
    input  logic [LOCAL_BUF_AW-1:0]             cur_n_base,
    input  logic                                dump_en,
    input  logic [LOCAL_BUF_AW-1:0]             dump_addr,
    output logic                                pe_compute_done,
    output logic                                pe_tile_done,

    // Dump output
    output logic signed [N_PE_ROW-1:0][ACC_W-1:0] c_out,
    output logic                                c_valid,

    // Simulation/debug tap at the pe_entry output
    output logic [15:0]                         dbg_ent_bitmask,
    output logic [15:0][7:0]                    dbg_ent_nz,
    output logic [4:0]                          dbg_ent_len,
    output logic                                dbg_ent_side,
    output logic [3:0]                          dbg_ent_idx,
    output logic                                dbg_ent_valid
);

    localparam int DRAIN = 6;                  // cycles from row done to final buffer update

    // =====================================================================
    // Input stream -> reconstructed fiber
    // =====================================================================
    logic [15:0]      ent_bm;
    logic [15:0][7:0] ent_nz;
    logic [4:0]       ent_len;
    logic             ent_side;
    logic [3:0]       ent_idx;
    logic             ent_valid;

    pe_entry u_entry (
        .clk(clk), .rst_n(rst_n),
        .pe_cfg_valid(pe_cfg_valid), .pe_cfg_ready(pe_cfg_ready),
        .pe_cfg_length(pe_cfg_length), .pe_cfg_bitmask(pe_cfg_bitmask),
        .pe_data_valid(pe_data_valid), .pe_data_ready(pe_data_ready),
        .pe_data_nzvalue(pe_data_nzvalue),
        .out_bitmask(ent_bm), .out_nz(ent_nz), .out_len(ent_len),
        .out_side(ent_side), .out_idx(ent_idx), .out_valid(ent_valid)
    );

    // =====================================================================
    // Shared A/B tile buffer
    // =====================================================================
    logic [15:0]      buf_a_bm [0:15];
    logic [15:0][7:0] buf_a_nz [0:15];
    logic [15:0]      buf_b_bm [0:15];
    logic [15:0][7:0] buf_b_nz [0:15];
    logic             tile_ready;

    pe_ab_buffer u_buf (
        .clk(clk), .rst_n(rst_n),
        .in_bitmask(ent_bm), .in_nz(ent_nz), .in_len(ent_len),
        .in_side(ent_side), .in_idx(ent_idx), .in_valid(ent_valid),
        .tile_ready(tile_ready),
        .a_bm(buf_a_bm), .a_nz(buf_a_nz), .a_len(),
        .b_bm(buf_b_bm), .b_nz(buf_b_nz), .b_len()
    );

    // Start all rows when the ordered tile transfer completes.
    wire start = tile_ready;

    // =====================================================================
    // 16 PE rows with private A and shared B data
    // =====================================================================
    logic done_row [0:15];
    logic cvld_row [0:15];

    genvar gr;
    generate
        for (gr = 0; gr < N_PE_ROW; gr = gr + 1) begin : g_row
            pe_row u_row (
                .clk(clk), .rst_n(rst_n),
                .mode(mode), .start(start), .done(done_row[gr]),
                .a_bm_row(buf_a_bm[gr]), .b_bm(buf_b_bm),
                .a_nz_row(buf_a_nz[gr]), .b_nz(buf_b_nz),
                .first_pass(first_pass), .cur_n_base(cur_n_base),
                .dump_en(dump_en), .dump_addr(dump_addr),
                .c_valid(cvld_row[gr]), .c_out(c_out[gr])
            );
        end
    endgenerate

    // All rows share the dump timing; row 0 provides the common valid.
    assign c_valid = cvld_row[0];

    // =====================================================================
    // Latch row completion pulses and drain the downstream pipeline.
    // =====================================================================
    logic   done_q [0:15];
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < N_PE_ROW; i = i + 1) done_q[i] <= 1'b0;
        end else begin
            for (i = 0; i < N_PE_ROW; i = i + 1) begin
                if (start)             done_q[i] <= 1'b0;
                else if (done_row[i])  done_q[i] <= 1'b1;
            end
        end
    end

    logic all_done;
    integer j;
    always_comb begin
        all_done = 1'b1;
        for (j = 0; j < N_PE_ROW; j = j + 1) all_done &= done_q[j];
    end

    logic [DRAIN-1:0] drain_sr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) drain_sr <= '0;
        else        drain_sr <= {drain_sr[DRAIN-2:0], all_done};
    end
    assign pe_compute_done = drain_sr[DRAIN-1];

    // Emit one completion pulse for each accepted tile.
    logic armed_q, cd_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin armed_q <= 1'b0; cd_q <= 1'b0; end
        else begin
            cd_q <= pe_compute_done;
            if (start)             armed_q <= 1'b1;
            else if (pe_tile_done) armed_q <= 1'b0;
        end
    end
    assign pe_tile_done = armed_q & pe_compute_done & ~cd_q;

    // pe_entry debug tap
    assign dbg_ent_bitmask = ent_bm;
    assign dbg_ent_nz      = ent_nz;
    assign dbg_ent_len     = ent_len;
    assign dbg_ent_side    = ent_side;
    assign dbg_ent_idx     = ent_idx;
    assign dbg_ent_valid   = ent_valid;

endmodule
