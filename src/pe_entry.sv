// =============================================================================
// pe_entry.sv — MC 封包 ingress / A·B 分流 (Iris)
// =============================================================================
// 角色:消費 MC 的 pe_cfg / pe_data 串流,把「一條壓縮 fiber」組回來,
//       依 header 的 A/B tag 標好 side,再吐給更下游的 A/B register(buffer)。
//
// 上游 (MC egress,沿用 MC 名稱):
//   - 1 拍 cfg :pe_cfg_valid + pe_cfg_length{[15]=is_b,[4:0]=len} + pe_cfg_bitmask
//   - ceil(len/4) 拍 data:pe_data_valid + pe_data_nzvalue(每拍 4 個 NZ,LSB-first)
//   背壓:本模組用 pe_cfg_ready / pe_data_ready 控制,MC 會等 ready 才前進。
//
// 下游 (A/B buffer):每組好一條 fiber 就拉 1 拍 out_valid(fire-and-forget;
//   目前假設下游恆收,若日後 buffer 要背壓再加 out_ready)。
//
// A/B 順序由 MC 保證(先整批 A、再整批 B);本模組只看 header tag 分流,不管順序。
// =============================================================================

module pe_entry (
    input  logic        clk,
    input  logic        rst_n,

    // ── 上游:MC egress ──
    input  logic        pe_cfg_valid,
    output logic        pe_cfg_ready,
    input  logic [15:0] pe_cfg_length,    // [15]=is_b(0=A/1=B), [4:0]=len(0..16)
    input  logic [15:0] pe_cfg_bitmask,
    input  logic        pe_data_valid,
    output logic        pe_data_ready,
    input  logic [31:0] pe_data_nzvalue,  // 4 個 NZ,LSB-first

    // ── 下游:組好的一條壓縮 fiber ──
    output logic [15:0]      out_bitmask,
    output logic [15:0][7:0] out_nz,       // 壓縮 NZ:nz[0..len-1] 有效
    output logic [4:0]       out_len,       // 0..16
    output logic             out_side,      // 0=A, 1=B
    output logic [3:0]       out_idx,       // 此封包在該 phase(A/B)的序號 0..15
    output logic             out_valid      // 1 拍 strobe
);

    // ── FSM ──
    typedef enum logic [1:0] { S_CFG, S_DATA, S_EMIT } state_t;
    state_t state;

    // ── latched header ──
    logic [15:0] bm_l;
    logic [4:0]  len_l;
    logic        side_l;
    logic [3:0]  idx_l;
    logic [2:0]  nwords;     // ceil(len/4), 0..4
    logic [2:0]  word_cnt;   // 已收 data word 數

    // ── NZ 累積(unpacked 陣列,變數索引安全)──
    logic [7:0]  nz_buf [0:15];

    // ── A/B phase 序號:side 一變就歸零 ──
    logic        prev_side;

    wire cfg_fire  = pe_cfg_valid  & pe_cfg_ready;
    wire data_fire = pe_data_valid & pe_data_ready;

    // 本封包 idx:與上一包同 side → +1,否則歸零
    wire [3:0] this_idx   = (pe_cfg_length[15] == prev_side) ? (idx_l + 4'd1) : 4'd0;
    // ceil(len/4):(len+3)>>2,len=0 → 0(顯式 cast 成 3-bit,消除 WIDTHTRUNC 警告)
    wire [2:0] this_nwords = 3'((pe_cfg_length[4:0] + 5'd3) >> 2);

    // ── ready:在對應 state 才收 ──
    assign pe_cfg_ready  = (state == S_CFG);
    assign pe_data_ready = (state == S_DATA);

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_CFG;
            bm_l      <= '0;
            len_l     <= '0;
            side_l    <= 1'b0;
            idx_l     <= 4'd0;
            nwords    <= 3'd0;
            word_cnt  <= 3'd0;
            prev_side <= 1'b1;   // 讓第一包(side=0)就歸零成 idx=0
            for (i = 0; i < 16; i = i + 1) nz_buf[i] <= 8'd0;
        end else begin
            case (state)
                // ── 收 cfg:latch header + 清 NZ buffer ──
                S_CFG: begin
                    if (cfg_fire) begin
                        side_l    <= pe_cfg_length[15];
                        len_l     <= pe_cfg_length[4:0];
                        bm_l      <= pe_cfg_bitmask;
                        idx_l     <= this_idx;
                        prev_side <= pe_cfg_length[15];
                        nwords    <= this_nwords;
                        word_cnt  <= 3'd0;
                        for (i = 0; i < 16; i = i + 1) nz_buf[i] <= 8'd0;
                        // [Iris] 空封包(len=0)直接吐,否則進 S_DATA 收 NZ
                        if (this_nwords == 3'd0) state <= S_EMIT;
                        else                     state <= S_DATA;
                    end
                end
                // ── 收 data:每拍拆 4 byte LSB-first ──
                S_DATA: begin
                    if (data_fire) begin
                        nz_buf[word_cnt*4 + 0] <= pe_data_nzvalue[7:0];
                        nz_buf[word_cnt*4 + 1] <= pe_data_nzvalue[15:8];
                        nz_buf[word_cnt*4 + 2] <= pe_data_nzvalue[23:16];
                        nz_buf[word_cnt*4 + 3] <= pe_data_nzvalue[31:24];
                        if (word_cnt == nwords - 3'd1) state <= S_EMIT;
                        word_cnt <= word_cnt + 3'd1;
                    end
                end
                // ── 吐一拍給下游 ──
                S_EMIT: begin
                    state <= S_CFG;
                end
                default: state <= S_CFG;
            endcase
        end
    end

    // ── 輸出 ──
    assign out_valid   = (state == S_EMIT);
    assign out_bitmask = bm_l;
    assign out_len     = len_l;
    assign out_side    = side_l;
    assign out_idx     = idx_l;

    genvar g;
    generate
        for (g = 0; g < 16; g = g + 1) begin : g_nz_pack
            assign out_nz[g] = nz_buf[g];
        end
    endgenerate

endmodule
