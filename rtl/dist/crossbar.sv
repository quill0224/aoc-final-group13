// =============================================================================
// crossbar.sv - TrIP operand gather
// =============================================================================
// 位於 pe_mfiu_seq 與 pe_row_tail 之間，依 MFIU metadata 從壓縮
// A/B fiber 取出各 multiplier lane 的運算元：
//   a_val[l] = a_nz_row[a_meta[l]]
//   b_col     = grp_base + b_meta[l][5:4]
//   b_val[l] = b_nz[b_col][b_meta[l][3:0]]
//
// a_meta 為目前 A fiber 的壓縮索引。
// b_meta[5:4] 為本批 B 的相對欄號，b_meta[3:0] 為該 B fiber 的壓縮索引。
// MFIU 將有效交集 compact 到低 lane，並依 B 相對欄號排列。lane_col
// 輸出 tile 內的實際 B 欄號，pe_row_tail 以此建立 reduction segment。
// l >= effectual 或 valid=0 時，該 lane 輸出清為 0，lane_valid=0。
//
// 每條 PE row 各有一個 crossbar。A 資料來自該 row 的 A fiber，
// B 資料則由 16 條 PE row 共用。此模組只用於 TrIP 路徑；StandardIP
// 目前由 pe_mfiu_seq bypass。模組本身為純組合邏輯。
// =============================================================================

module crossbar
    import trapezoid_pkg::*;
(
    // MFIU metadata for the current B batch
    input  logic                      valid,
    input  logic [LANE_COUNT_W-1:0]   effectual,
    input  logic [N_MUL_ROW-1:0][3:0] a_meta,
    input  logic [N_MUL_ROW-1:0][5:0] b_meta,
    input  logic [3:0]                grp_base,

    // Compressed values from pe_ab_buffer
    input  logic [15:0][7:0]          a_nz_row,        // A fiber for this PE row
    input  logic [15:0][7:0]          b_nz [0:15],     // 16 shared B fibers

    // Operands and column tags for the PE-row datapath
    output logic [7:0]                a_val [0:15],     // unsigned A operand
    output logic [7:0]                b_val [0:15],     // signed B stored on an 8-bit bus
    output logic [3:0]                lane_col [0:15],  // output column of each lane
    output logic                      lane_valid [0:15],
    output logic                      valid_out
);

    // Convert packed ports to arrays used by the indexed gather logic.
    logic [7:0] a_u [0:15];
    logic [7:0] b_u [0:15][0:15];   // [B column][compressed index]
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

    // Gather one A/B operand pair for each active lane.
    integer l; logic [4:0] col5;
    always_comb begin
        for (l = 0; l < N_MUL_ROW; l = l + 1) begin
            col5 = {1'b0, grp_base} + {3'b0, bm[l][5:4]};   // tile column = batch base + relative column
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
