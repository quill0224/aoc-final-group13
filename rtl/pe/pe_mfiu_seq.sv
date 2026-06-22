// =============================================================================
// pe_mfiu_seq.sv — per-PE-row MFIU sequencer (Iris)  [Step B-1]
// =============================================================================
// 把 buffer 的「這條 A row bitmask + 16 條 B col bitmask」餵進一顆 mfiu:
//   * 動態分組:從目前 col 起貪婪取最多 N_B_FIBER(4) 條 B,且 group 內
//     effectual = Σ popcount(a & b_col) ≤ N_MUL_ROW(16) 才繼續加(popcount
//     預估,塞滿不 overflow;單欄 popcount≤16 必成立 → 每 group 至少 1 條)。
//   * 驅動 mfiu 握手:每 group 重新 LOAD_A(同一條 a),a_last 只在最後一個
//     group 拉、b_group_last 全 0(乾淨終止 mfiu FSM)。
//   * mode=1(TrIP)才啟動;mode=0(StandardIP)mfiu 保持 IDLE(bypass)。
//   * 每 group 一拍輸出 a_meta/b_meta/effectual 給下游 crossbar,附這個 group
//     的真實起始 col(grp_base)與欄數(grp_ncol);crossbar:真實col = grp_base
//     + b_meta[lane][5:4](group 內 col 連續)。
// mfiu 在本模組內 instantiate(= 一個 PE row 的交集單元)。
// =============================================================================

module pe_mfiu_seq
    import trapezoid_pkg::*;
(
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       mode,       // 1=TrIP, 0=StandardIP
    input  logic                       start,      // 1 拍:開始處理這條 A row
    output logic                       done,       // 1 拍:所有 B group 處理完

    input  logic [N_MUL_ROW-1:0]       a_bm_row,        // A fiber bitmask
    input  logic [N_MUL_ROW-1:0]       b_bm [0:15],     // 16 B col bitmasks (一個 tile)

    // 每個 group 一拍輸出(給下游 crossbar)
    output logic                       out_valid,
    output logic [LANE_COUNT_W-1:0]    out_effectual,
    output logic [N_MUL_ROW-1:0][3:0]  out_a_meta,
    output logic [N_MUL_ROW-1:0][5:0]  out_b_meta,
    output logic [3:0]                 out_grp_base,    // group 起始真實 col 0..15
    output logic [2:0]                 out_grp_ncol     // 1..4
);

    localparam int NB_COLS = 16;          // B cols per tile
    localparam int MAXG    = N_B_FIBER;   // 4 max cols / group

    // 16-bit popcount
    function automatic [4:0] popcnt16(input logic [N_MUL_ROW-1:0] x);
        integer i; logic [4:0] s;
        begin s = 5'd0; for (i = 0; i < N_MUL_ROW; i = i + 1) s = s + x[i]; popcnt16 = s; end
    endfunction

    typedef enum logic [2:0] { S_IDLE, S_LOADA, S_WAITB, S_WAIT, S_DONE } st_t;
    st_t        state;
    logic [4:0] col_ptr;   // 0..16 (下一個要分組的 col)

    // ── 動態分組:從 col_ptr 貪婪取 ≤MAXG 條、cum effectual ≤ N_MUL_ROW ──
    logic [2:0] ncol;
    logic [5:0] cum, e;    // 6-bit:cum+e 最大 32,避免溢位
    logic       stopped;
    integer     gi; logic [4:0] cidx;
    always_comb begin
        ncol = 3'd0; cum = 6'd0; stopped = 1'b0; cidx = 5'd0; e = 6'd0;
        for (gi = 0; gi < MAXG; gi = gi + 1) begin
            cidx = col_ptr + gi[4:0];
            if (!stopped && (cidx < NB_COLS[4:0])) begin
                e = {1'b0, popcnt16(a_bm_row & b_bm[cidx])};
                if (gi == 0 || ((cum + e) <= 6'(N_MUL_ROW))) begin
                    cum  = cum + e;
                    ncol = ncol + 3'd1;
                end else begin
                    stopped = 1'b1;   // 再加會 overflow → 收尾這個 group
                end
            end
        end
    end
    wire is_last = ((col_ptr + ncol) >= NB_COLS[4:0]);

    // ── group bitmasks(unpacked 變數索引安全 → 再 pack 給 mfiu)──
    logic [N_MUL_ROW-1:0] b_grp [0:MAXG-1];
    integer bj;
    always_comb begin
        for (bj = 0; bj < MAXG; bj = bj + 1) begin
            if ((bj < ncol) && ((col_ptr + bj[4:0]) < NB_COLS[4:0]))
                b_grp[bj] = b_bm[col_ptr + bj[4:0]];
            else
                b_grp[bj] = '0;
        end
    end

    // ── mfiu I/O ──
    logic                                  mfiu_a_in_valid, mfiu_b_in_valid;
    logic                                  mfiu_a_last;
    logic [N_B_FIBER-1:0][N_MUL_ROW-1:0]   mfiu_b_bitmask;
    logic [$clog2(N_B_FIBER)-1:0]          mfiu_b_col_valid;
    logic [LANE_COUNT_W-1:0]               mfiu_effectual;
    logic [N_MUL_ROW-1:0][3:0]             mfiu_a_meta;
    logic [N_MUL_ROW-1:0][5:0]             mfiu_b_meta;
    logic                                  mfiu_meta_valid;

    genvar gj;
    generate
        for (gj = 0; gj < N_B_FIBER; gj = gj + 1) begin : g_bpack
            assign mfiu_b_bitmask[gj] = b_grp[gj];
        end
    endgenerate

    assign mfiu_a_in_valid  = (state == S_LOADA);
    assign mfiu_b_in_valid  = (state == S_WAITB);
    assign mfiu_a_last      = (state == S_LOADA) && is_last;
    assign mfiu_b_col_valid = 2'(ncol - 3'd1);   // 0..3 = 1..4 cols

    mfiu u_mfiu (
        .clk(clk), .rst_n(rst_n),
        .en(mode), .mode(mode),
        .a_in_valid(mfiu_a_in_valid), .b_in_valid(mfiu_b_in_valid),
        .a_last(mfiu_a_last), .b_group_last(1'b0),
        .a_bitmask(a_bm_row), .b_bitmask(mfiu_b_bitmask), .b_col_valid(mfiu_b_col_valid),
        .effectual_count(mfiu_effectual), .a_meta_data(mfiu_a_meta),
        .b_meta_data(mfiu_b_meta), .meta_valid(mfiu_meta_valid)
    );

    // ── sequencer FSM ──
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; col_ptr <= 5'd0;
        end else begin
            unique case (state)
                S_IDLE: begin
                    col_ptr <= 5'd0;
                    if (start &&  mode) state <= S_LOADA;
                    else if (start)     state <= S_DONE;   // StandardIP:不跑 mfiu,直接收尾
                end
                S_LOADA: state <= S_WAITB;
                S_WAITB: state <= S_WAIT;
                S_WAIT:  if (mfiu_meta_valid) begin
                             col_ptr <= col_ptr + ncol;
                             if (is_last) state <= S_DONE;
                             else         state <= S_LOADA;
                         end
                S_DONE:  state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end

    assign out_valid     = (state == S_WAIT) && mfiu_meta_valid;
    assign out_effectual = mfiu_effectual;
    assign out_a_meta    = mfiu_a_meta;
    assign out_b_meta    = mfiu_b_meta;
    assign out_grp_base  = col_ptr[3:0];
    assign out_grp_ncol  = ncol;
    assign done          = (state == S_DONE);

endmodule
