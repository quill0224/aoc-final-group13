// =============================================================================
// pe_ab_buffer.sv — A/B fiber buffer (Iris)
// =============================================================================
// 收 pe_entry 每拍吐的一條壓縮 fiber,依 side 寫進 A buffer 或 B buffer 的第 idx 格。
// 一個 tile = 16 條 A fiber(每個 PE row 一條)+ 16 條 B fiber(每個 B 欄一條)。
// 每格存:原始 bitmask[16] + 壓縮 nz[16×8] + len。
//   - bitmask → 之後餵新 MFIU(做交集 → a_meta/b_meta)
//   - 壓縮 nz → 之後給 crossbar 用 meta 取值
// 收滿(B 段最後一格 idx15 落地)拉 1 拍 tile_ready。
//
// 讀側 = unpacked-by-fiber 陣列(用 fiber index 讀:bm→MFIU、nz→crossbar)。
// 注意:此模組只做「存 + 用 index 讀」,不碰 MFIU 握手 / 動態分組(那是後面的 sequencer)。
// =============================================================================

module pe_ab_buffer (
    input  logic              clk,
    input  logic              rst_n,

    // ── 上游:pe_entry(沿用 out_*)──
    input  logic [15:0]       in_bitmask,
    input  logic [15:0][7:0]  in_nz,      // 壓縮 NZ:nz[0..len-1]
    input  logic [4:0]        in_len,
    input  logic              in_side,    // 0=A, 1=B
    input  logic [3:0]        in_idx,     // 0..15
    input  logic              in_valid,

    // ── tile 狀態 ──
    output logic              tile_ready, // 16 A + 16 B 收齊(B idx15 落地時拉 1 拍)

    // ── 讀側:unpacked-by-fiber(輸出埠直接當儲存)──
    output logic [15:0]       a_bm  [0:15],  // [16 fiber] 16-bit mask  → MFIU
    output logic [15:0][7:0]  a_nz  [0:15],  // [16 fiber] 16 nz × 8b   → crossbar
    output logic [4:0]        a_len [0:15],
    output logic [15:0]       b_bm  [0:15],  // [16 col]                → MFIU
    output logic [15:0][7:0]  b_nz  [0:15],  //                         → crossbar
    output logic [4:0]        b_len [0:15]
);

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 16; i = i + 1) begin
                a_bm[i] <= '0; a_nz[i] <= '0; a_len[i] <= '0;
                b_bm[i] <= '0; b_nz[i] <= '0; b_len[i] <= '0;
            end
        end else if (in_valid) begin
            if (!in_side) begin   // A
                a_bm[in_idx]  <= in_bitmask;
                a_nz[in_idx]  <= in_nz;
                a_len[in_idx] <= in_len;
            end else begin        // B
                b_bm[in_idx]  <= in_bitmask;
                b_nz[in_idx]  <= in_nz;
                b_len[in_idx] <= in_len;
            end
        end
    end

    // 收滿一個 tile:B 段最後一格(idx 15)落地
    assign tile_ready = in_valid && in_side && (in_idx == 4'd15);

endmodule
