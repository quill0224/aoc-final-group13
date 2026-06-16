// =============================================================================
// trapezoid_pkg.sv — Group 13 共用參數 (Single Source of Truth)
// =============================================================================
// 全組共用參數;改任何 parameter 前先在 group chat 知會
// 規則: 改任何 parameter 前必須在 group chat 知會,因為每個人的模組都會 import 進來
// =============================================================================

package trapezoid_pkg;

  // ==========================================================================
  // PE Array 尺寸
  // ==========================================================================
  parameter int N_PE_ROW    = 16;                          // PE row 數
  parameter int N_MUL_ROW   = 16;                          // 每 row 的 multiplier 數
  parameter int N_TOTAL_MAC = N_PE_ROW * N_MUL_ROW;        // 256

  // ==========================================================================
  // 資料寬度 (依 proposal: INT8 量化)
  // ==========================================================================
  parameter int DATA_W      = 8;     // INT8 input
  parameter int PROD_W      = 16;    // INT8 × INT8 = INT16
  parameter int ACC_W       = 32;    // INT32 accumulator (proposal 確定)

  // ==========================================================================
  // Tiling (proposal 4.4: 32×32 tile)
  // ==========================================================================
  parameter int TILE_M      = 32;
  parameter int TILE_N      = 32;
  parameter int TILE_K      = 32;

  // ==========================================================================
  // Memory (proposal 4.2: ADFP 16×1KB SRAM)
  // ==========================================================================
  parameter int N_BANK      = 16;
  parameter int BANK_DEPTH  = 128;                          // 128 words
  parameter int BANK_W_BITS = 64;                           // 64 bits / word
  parameter int BANK_BYTES  = BANK_DEPTH * BANK_W_BITS / 8; // 1024 B = 1 KB
  parameter int TOTAL_SRAM  = N_BANK * BANK_BYTES;          // 16 KB

  // ==========================================================================
  // Sparse 結構 (TrIP fiber packing)
  // ==========================================================================
  parameter int N_A_FIBER   = 4;     // 同時 pack 4 列 A
  parameter int N_B_FIBER   = 4;     // 同時 stream 4 行 B
  // 4 × 4 = 16 個 intersection candidate / cycle = 1 個 PE row 寬度

  // ==========================================================================
  // Dataflow mode encoding
  // ==========================================================================
  parameter logic [1:0] MODE_DENSE_IP = 2'b00;   // baseline
  parameter logic [1:0] MODE_TRIP     = 2'b01;   // 主要目標
  parameter logic [1:0] MODE_TRGT     = 2'b10;   // stretch goal
  parameter logic [1:0] MODE_TRGS     = 2'b11;   // stretch goal

  // ==========================================================================
  // Quantization scheme (討論結果寫進來)
  // ==========================================================================
  // Symmetric: zero-point = 0,INT8 的 0 就是真實 0,bitmask sparsity 才成立
  // 若改 asymmetric,bitmask 邏輯需重做 (見 docs/spec_open_questions.md #1)
  parameter bit USE_SYMMETRIC_QUANT = 1'b1;

  // ==========================================================================
  // Pipeline 階段數 (依 dataflow)
  // 對齊 PPTX p.13/p.14:
  //   Dense IP (7):  latch_b(1) → mul(1) → tree(4) → acc/out(1)
  //   TrIP     (9):  latch_b(1) → MFIU intersect+prefix(2) → mul(1) → tree(4) → acc/out(1)
  // ==========================================================================
  parameter int IP_STAGES   = 7;    // (舊版 pe_row,單 tree;完整版改用下面 PE_ROW_STAGES)
  parameter int TRIP_STAGES = 9;    // (舊草稿值,placeholder)

  // ==========================================================================
  // 完整 PE Row 微架構 pipeline (paper Fig 6)
  //   單一物理 pipeline (Δ5 Option A):Dense IP 也走 MFIU + dist (pass-through delay)
  //   tree 改用 flexagon (1-cycle combinational + 1 output register)
  //   詳見 docs/pe-row-full-architecture.md
  // ==========================================================================
  parameter int LATCH_STAGES = 1;   // S1   輸入打拍 (A Reg + B FIFO)
  parameter int MFIU_STAGES  = 3;   // S2-4 intersect + prefix-sum + shift(暫定,待確認)
  parameter int DIST_STAGES  = 1;   // S5   A/B distribution crossbar registered output
  parameter int MUL_STAGES   = 1;   // S6   mac_unit registered
  parameter int TREE_STAGES  = 1;   // S7   flexagon tree (combinational + 1 output reg)
  parameter int BUF_STAGES   = 1;   // S8   local buffer RMW + C out
  parameter int PE_ROW_STAGES = LATCH_STAGES + MFIU_STAGES + DIST_STAGES
                              + MUL_STAGES + TREE_STAGES + BUF_STAGES;  // = 8

  // ==========================================================================
  // Per-row Local Buffer (paper §III.B:4 banks × 4-word wide scatter buffer)
  // ==========================================================================
  parameter int LOCAL_BUF_DEPTH = 512;                     // VGG-16 max N (output channels)
  parameter int LOCAL_BUF_AW    = $clog2(LOCAL_BUF_DEPTH); // 9 bits
  parameter int N_BANK_LBUF     = 4;                       // 4 banks (paper §III.B)
  parameter int LBUF_WORD_WIDE  = 4;                       // 4-word wide → 16 scatter writes/cycle

  // ==========================================================================
  // Bitmask 寬度 (MFIU 用)
  // ==========================================================================
  parameter int BITMASK_W = N_MUL_ROW;                     // 16

endpackage : trapezoid_pkg
