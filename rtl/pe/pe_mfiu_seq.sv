// =============================================================================
// pe_mfiu_seq.sv -- per-PE-row MFIU sequencer
// =============================================================================
// 一個 PE row 的交集單元前端:把 buffer 的「這條 A row bitmask + 16 條 B col
// bitmask」逐批餵進一顆 mfiu。
//
// 分工(動態分組已收進 mfiu):
//   * 本模組只負責「從 col_ptr 起送最多 N_B_FIBER(4) 條 B」,並依 mfiu 回報的
//     b_utilization 推進 col_ptr。實際要吃幾條、effectual<=N_MUL_ROW 的保證,
//     都由 mfiu 內部決定(交集前綴貪婪打包)。
//   * mfiu 回報 b_utilization = 本批實際使用的欄數-1。若 mfiu 沒吃完整批
//     (complete_col=0),它會回到 WAIT_B 等下一批,本模組就把剩下的欄再送一次。
//   * a_last 必須與 b_in_valid 同階段(mfiu 在 WAIT_B 才鎖存 a_last);因此在
//     「送出包含最後一欄(col 15)的那一批」時拉 a_last,讓 mfiu 收尾回 IDLE。
//     b_group_last 全程 0(一條 A row,用 a_last 終止即可)。
//   * mode=0(StandardIP)時 mfiu 保持 IDLE,本模組直接收尾(bypass)。
//   * 每批一拍輸出 a_meta/b_meta/effectual 給下游 crossbar,附本批真實起始 col
//     (grp_base)與本批實際欄數(grp_ncol);crossbar:真實 col = grp_base +
//     b_meta[lane][5:4]。
//
// 時序假設:mode 在 start 之前已穩定為 1,故 mfiu 已停在 LOAD_A 等候 a_in_valid。
// =============================================================================

module pe_mfiu_seq
    import trapezoid_pkg::*;
(
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       mode,       // 1=TrIP, 0=StandardIP
    input  logic                       start,      // 1 拍:開始處理這條 A row
    output logic                       done,       // 1 拍:所有 B 欄處理完

    input  logic [N_MUL_ROW-1:0]       a_bm_row,        // A fiber bitmask
    input  logic [N_MUL_ROW-1:0]       b_bm [0:15],     // 16 B col bitmasks (一個 tile)

    // 每批一拍輸出(給下游 crossbar)
    output logic                       out_valid,
    output logic [LANE_COUNT_W-1:0]    out_effectual,
    output logic [N_MUL_ROW-1:0][3:0]  out_a_meta,
    output logic [N_MUL_ROW-1:0][5:0]  out_b_meta,
    output logic [3:0]                 out_grp_base,    // 本批起始真實 col 0..15
    output logic [2:0]                 out_grp_ncol     // 本批實際使用欄數 1..4
);

    localparam int NB_COLS = 16;          // B cols per tile
    localparam int MAXG    = N_B_FIBER;   // 4 max cols / batch

    typedef enum logic [2:0] { S_IDLE, S_LOADA, S_SENDB, S_WAIT, S_DONE } st_t;
    st_t        state;
    logic [4:0] col_ptr;   // 0..16:下一個要送的 col

    // ── 本批要送幾欄:從 col_ptr 起、最多 MAXG,不超過剩餘欄數 ──
    //    (這只是「還剩幾欄可送」,不是依 effectual 的動態分組;分組在 mfiu 內)
    logic [2:0] valid_cols;
    always_comb begin
        if ((NB_COLS[4:0] - col_ptr) >= 5'd4) valid_cols = 3'd4;
        else                                  valid_cols = 3'(NB_COLS[4:0] - col_ptr);
    end
    // 本批是否含最後一欄(col 15)→ 要拉 a_last 讓 mfiu 收尾
    wire is_last_batch = ((col_ptr + {2'b0, valid_cols}) >= NB_COLS[4:0]);

    // ── 取出本批 col(unpacked 變數索引安全 → 再 pack 給 mfiu)──
    logic [N_MUL_ROW-1:0] b_batch [0:MAXG-1];
    integer bj;
    always_comb begin
        for (bj = 0; bj < MAXG; bj = bj + 1) begin
            if ((bj < valid_cols) && ((col_ptr + bj[4:0]) < NB_COLS[4:0]))
                b_batch[bj] = b_bm[col_ptr + bj[4:0]];
            else
                b_batch[bj] = '0;
        end
    end

    // ── mfiu I/O ──
    logic                                  mfiu_a_in_valid, mfiu_b_in_valid, mfiu_a_last;
    logic [N_B_FIBER-1:0][N_MUL_ROW-1:0]   mfiu_b_bitmask;
    logic [$clog2(N_B_FIBER)-1:0]          mfiu_b_col_valid;
    logic [LANE_COUNT_W-1:0]               mfiu_effectual;
    logic [N_MUL_ROW-1:0][3:0]             mfiu_a_meta;
    logic [N_MUL_ROW-1:0][5:0]             mfiu_b_meta;
    logic [$clog2(N_B_FIBER)-1:0]          mfiu_b_util;
    logic                                  mfiu_meta_valid;

    genvar gj;
    generate
        for (gj = 0; gj < N_B_FIBER; gj = gj + 1) begin : g_bpack
            assign mfiu_b_bitmask[gj] = b_batch[gj];
        end
    endgenerate

    assign mfiu_a_in_valid  = (state == S_LOADA);
    assign mfiu_b_in_valid  = (state == S_SENDB);
    assign mfiu_a_last      = (state == S_SENDB) && is_last_batch;   // 與 b_in_valid 同階段
    assign mfiu_b_col_valid = 2'(valid_cols - 3'd1);                 // 0..3 = 1..4 cols

    mfiu u_mfiu (
        .clk(clk), .rst_n(rst_n),
        .en(mode), .mode(mode),
        .a_in_valid(mfiu_a_in_valid), .b_in_valid(mfiu_b_in_valid),
        .a_last(mfiu_a_last), .b_group_last(1'b0),
        .a_bitmask(a_bm_row), .b_bitmask(mfiu_b_bitmask), .b_col_valid(mfiu_b_col_valid),
        .effectual_count(mfiu_effectual), .a_meta_data(mfiu_a_meta),
        .b_meta_data(mfiu_b_meta), .b_utilization(mfiu_b_util), .meta_valid(mfiu_meta_valid)
    );

    // mfiu 實際吃掉的欄數 = b_utilization + 1;據此推進 col_ptr
    wire [2:0] used_cols = 3'(mfiu_b_util) + 3'd1;
    wire [4:0] next_ptr  = col_ptr + {2'b0, used_cols};

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
                S_LOADA: state <= S_SENDB;                 // mfiu LOAD_A -> WAIT_B
                S_SENDB: state <= S_WAIT;                  // mfiu WAIT_B -> CAL
                S_WAIT:  if (mfiu_meta_valid) begin        // mfiu OUT:本批 meta 有效
                             col_ptr <= next_ptr;
                             if (next_ptr >= NB_COLS[4:0]) state <= S_DONE;   // 送完最後一欄 -> mfiu 回 IDLE
                             else                          state <= S_SENDB;  // 還有欄(含未吃完的)-> 再送一批
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
    assign out_grp_base  = col_ptr[3:0];     // 本批起始 col(尚未推進)
    assign out_grp_ncol  = used_cols;        // = b_utilization + 1
    assign done          = (state == S_DONE);

endmodule
