// =============================================================================
// pe_array.sv — 16 條 PE row 的陣列(Trapezoid-Lite,新版)
// =============================================================================
// 整個 PE 子系統:吃 MC egress 串流,內含
//   pe_entry → pe_ab_buffer(共享) → 16 × pe_row(各自 mfiu_seq→crossbar→tail)
// 取代舊的 SIGMA-style systolic 版(B 垂直鏈 + pe_row_full,已退役)。
//
// 分配(位置決定,無排程器):
//   MC 先送 16 條 A、再送 16 欄 B;pe_entry 的 out_idx 在每個 phase 數 0..15,
//   pe_ab_buffer 照 idx 落格;PE row r 讀 buffer 第 r 條 A(a_nz[r]),B 16 欄共享。
//   → 「A 的第幾列 → 第幾條 row」= MC 送 A 的順序。
//
// 啟動 / 完成握手:
//   start        = pe_ab_buffer.tile_ready(收滿一個 tile 拉 1 拍)→ 16 row 一起跑。
//   pe_compute_done = 16 row 的 mfiu_seq.done 全部到齊(各 row 鎖存)再延遲 DRAIN 拍
//                     (等 tail 的 local_buffer 累加落定)。
//   ⚠️ controller 要等 pe_compute_done(不是只等 MC 的 k_done = 封包送完),
//      否則下一批 tile 會在還沒算完時覆寫 pe_ab_buffer。
//
// dump:dump_en/dump_addr 由 controller/上層廣播;16 row 同步讀同一欄 →
//   c_out[0..15] = 該欄跨 16 個輸出列的 psum,c_valid 同步。
//
// ⚠️ 含 mfiu(在 pe_row 內)→ 需 verilator elaborate(iverilog 不支援)。
// =============================================================================

module pe_array
    import trapezoid_pkg::*;
(
    input  logic                                clk,
    input  logic                                rst_n,

    // ── MC egress(沿用 pe_entry 名稱;未來 integration 把裸 pe_entry 換成本模組)──
    input  logic                                pe_cfg_valid,
    output logic                                pe_cfg_ready,
    input  logic [15:0]                         pe_cfg_length,    // [15]=is_b, [4:0]=len
    input  logic [15:0]                         pe_cfg_bitmask,
    input  logic                                pe_data_valid,
    output logic                                pe_data_ready,
    input  logic [31:0]                         pe_data_nzvalue,

    // ── controller ──
    input  logic [1:0]                          mode,             // = global_mode (MODE_TRIP=01)
    input  logic                                first_pass,       // = pe_first_pass (k_cnt==0)
    input  logic [LOCAL_BUF_AW-1:0]             cur_n_base,       // = pe_cur_n_base (n_cnt*16)
    input  logic                                dump_en,
    input  logic [LOCAL_BUF_AW-1:0]             dump_addr,
    output logic                                pe_compute_done,  // → controller 等這個才換 tile

    // ── C 輸出(dump 時:一欄跨 16 列的 psum)──
    output logic signed [N_PE_ROW-1:0][ACC_W-1:0] c_out,
    output logic                                c_valid,

    // ── 觀察用(sim):透出內部 pe_entry 組好的 fiber(沿用 integration 原 pe_out_* DEBUG/trace)──
    output logic [15:0]                         dbg_ent_bitmask,
    output logic [15:0][7:0]                    dbg_ent_nz,
    output logic [4:0]                          dbg_ent_len,
    output logic                                dbg_ent_side,
    output logic [3:0]                          dbg_ent_idx,
    output logic                                dbg_ent_valid
);

    localparam int DRAIN = 6;                  // tail drain margin(done → buffer 累加落定)
    wire row_mode = (mode == MODE_TRIP);

    // =====================================================================
    // pe_entry:MC 串流 → 一條壓縮 fiber + strobe
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
    // pe_ab_buffer(共享):16 條 A + 16 欄 B,收滿拉 tile_ready
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
        .a_bm(buf_a_bm), .a_nz(buf_a_nz), .a_len(),   // a_len/b_len 不用 → 留空
        .b_bm(buf_b_bm), .b_nz(buf_b_nz), .b_len()
    );

    // 收滿一個 tile → 16 row 一起開跑(mfiu_seq 在 S_IDLE,start 1 拍)
    wire start = tile_ready;

    // =====================================================================
    // 16 × pe_row(各自 mfiu_seq→crossbar→tail);A 取自己那條、B 共享
    // =====================================================================
    logic done_row [0:15];
    logic cvld_row [0:15];

    genvar gr;
    generate
        for (gr = 0; gr < N_PE_ROW; gr = gr + 1) begin : g_row
            pe_row u_row (
                .clk(clk), .rst_n(rst_n),
                .mode(row_mode), .start(start), .done(done_row[gr]),
                .a_bm_row(buf_a_bm[gr]), .b_bm(buf_b_bm),
                .a_nz_row(buf_a_nz[gr]), .b_nz(buf_b_nz),
                .first_pass(first_pass), .cur_n_base(cur_n_base),
                .dump_en(dump_en), .dump_addr(dump_addr),
                .c_valid(cvld_row[gr]), .c_out(c_out[gr])
            );
        end
    endgenerate

    // 16 row 同步 dump → 用 row0 當代表
    assign c_valid = cvld_row[0];

    // =====================================================================
    // pe_compute_done:鎖存每條 row 的 done(脈衝)→ 全到齊 → 延遲 DRAIN 拍
    //   start(新 tile)清掉鎖存;controller 等 pe_compute_done 才推進下一批。
    // =====================================================================
    logic   done_q [0:15];
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < N_PE_ROW; i = i + 1) done_q[i] <= 1'b0;
        end else begin
            for (i = 0; i < N_PE_ROW; i = i + 1) begin
                if (start)             done_q[i] <= 1'b0;        // 新 tile:清
                else if (done_row[i])  done_q[i] <= 1'b1;        // 此 row 算完:鎖存
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

    // 觀察 tap:= 內部 pe_entry 輸出(給 integration 沿用原 pe_out_* DEBUG,不影響功能)
    assign dbg_ent_bitmask = ent_bm;
    assign dbg_ent_nz      = ent_nz;
    assign dbg_ent_len     = ent_len;
    assign dbg_ent_side    = ent_side;
    assign dbg_ent_idx     = ent_idx;
    assign dbg_ent_valid   = ent_valid;

endmodule
