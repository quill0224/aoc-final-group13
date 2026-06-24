// =============================================================================
// crossbar.sv — TrIP value gather
// =============================================================================
// 把 pe_mfiu_seq 的 per-lane meta「翻譯」成真正的 A/B 壓縮值,餵給 mac x16:
//   a_val[l] = a_nz_row[ a_meta[l] ]                  (這條 A fiber 的壓縮值)
//   b_col[l] = grp_base + b_meta[l][5:4]              (真實輸出欄 0..15)
//   b_val[l] = b_nz[ b_col[l] ][ b_meta[l][3:0] ]     (該欄的 B 壓縮值)
//   無效 lane(l >= effectual)→ 值=0、lane_valid=0
// 每個 PE row 一顆:A 用自己那條(a_nz_row = buffer.a_nz[r]);B 共用(b_nz = buffer.b_nz)。
// 純組合(下游 mac 會 register);介面只對齊 pe_mfiu_seq 與 pe_ab_buffer。
// =============================================================================

module crossbar
    import trapezoid_pkg::*;
(
    // ── from pe_mfiu_seq(此 row 這個 group)──
    input  logic                      valid,
    input  logic [LANE_COUNT_W-1:0]   effectual,
    input  logic [N_MUL_ROW-1:0][3:0] a_meta,
    input  logic [N_MUL_ROW-1:0][5:0] b_meta,
    input  logic [3:0]                grp_base,

    // ── from pe_ab_buffer ──
    input  logic [15:0][7:0]          a_nz_row,        // = buffer.a_nz[r]
    input  logic [15:0][7:0]          b_nz [0:15],     // = buffer.b_nz (16 欄)

    // ── to mac x16 + reduction ──
    output logic [7:0]                a_val [0:15],     // A=uint8
    output logic [7:0]                b_val [0:15],     // B=int8
    output logic [3:0]                lane_col [0:15],  // 每 lane 對到的輸出欄(給 reduction 分組)
    output logic                      lane_valid [0:15],
    output logic                      valid_out
);

    // ── flatten packed → unpacked ──
    logic [7:0] a_u [0:15];
    logic [7:0] b_u [0:15][0:15];   // [col][idx]
    logic [3:0] am  [0:15];
    logic [5:0] bm  [0:15];
    genvar gi, gc, gx;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : g_flat
            assign a_u[gi] = a_nz_row[gi];
            assign am[gi]  = a_meta[gi];
            assign bm[gi]  = b_meta[gi];
        end
        for (gc = 0; gc < 16; gc = gc + 1) begin : g_bcol
            for (gx = 0; gx < 16; gx = gx + 1) begin : g_bidx
                assign b_u[gc][gx] = b_nz[gc][gx];
            end
        end
    endgenerate

    // ── per-lane gather ──
    integer l; logic [4:0] col5;
    always_comb begin
        for (l = 0; l < N_MUL_ROW; l = l + 1) begin
            col5 = {1'b0, grp_base} + {3'b0, bm[l][5:4]};   // 真實欄 = grp_base + group內欄
            if (valid && (l < effectual)) begin
                a_val[l]      = a_u[ am[l] ];
                b_val[l]      = b_u[ col5[3:0] ][ bm[l][3:0] ];
                lane_col[l]   = col5[3:0];
                lane_valid[l] = 1'b1;
            end else begin
                a_val[l]      = 8'd0;
                b_val[l]      = 8'd0;
                lane_col[l]   = 4'd0;
                lane_valid[l] = 1'b0;
            end
        end
    end

    assign valid_out = valid;

endmodule
