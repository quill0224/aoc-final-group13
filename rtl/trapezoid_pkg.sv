// =============================================================================
// trapezoid_pkg.sv -- PE row common parameters
// =============================================================================
// Scope:
//   16x16 PE array, Dense IP and TrIP only.
//   This package describes PE-row datapath widths, MFIU sizing, and local
//   row-buffer parameters. Packet and AXI/GLB bus parameters live outside RTL/PE.
// =============================================================================

package trapezoid_pkg;

  // PE array shape: 16 rows x 16 multiplier lanes = 256 MACs.
  // This matches the current ASIC.svh PE_ARRAY_* system shape.
  parameter int N_PE_ROW    = 16;
  parameter int N_MUL_ROW   = 16;
  parameter int N_TOTAL_MAC = N_PE_ROW * N_MUL_ROW;

  // PE compute widths. DATA_W is not the AXI/GLB bus width.
  parameter int DATA_W = 8;           // PE input value width, not AXI/GLB bus width.
  parameter int PROD_W = 2 * DATA_W;  // INT8 x INT8 product width.
  parameter int ACC_W  = 32;          // Partial-sum width.

  // Dataflow mode encoding. Only Dense IP and TrIP are implemented.
  // These values must stay consistent with ASIC.svh MODE_STD_IP / MODE_TRIP.
  parameter logic [1:0] MODE_DENSE_IP   = 2'b00;
  parameter logic [1:0] MODE_TRIP       = 2'b01;
  parameter logic [1:0] MODE_RESERVED_2 = 2'b10;
  parameter logic [1:0] MODE_RESERVED_3 = 2'b11;

  // TrIP / MFIU sizing.
  parameter int BITMASK_W  = 16;  // Current K window width.
  parameter int N_A_FIBER  = 4;   // Max A fibers visible to one PE row.
  parameter int N_B_FIBER  = 4;   // Hardware B-fiber capacity; runtime may activate only 1/2/4.

  // Derived index widths.
  // LANE_IDX_W indexes lanes 0..15; LANE_COUNT_W counts valid lanes 0..16.
  parameter int LANE_IDX_W    = (N_MUL_ROW      > 1) ? $clog2(N_MUL_ROW)      : 1;
  parameter int LANE_COUNT_W  = (N_MUL_ROW      > 0) ? $clog2(N_MUL_ROW + 1)  : 1;
  parameter int K_IDX_W       = (BITMASK_W      > 1) ? $clog2(BITMASK_W)      : 1;
  parameter int A_FIBER_IDX_W = (N_A_FIBER      > 1) ? $clog2(N_A_FIBER)      : 1;
  parameter int B_FIBER_IDX_W = (N_B_FIBER      > 1) ? $clog2(N_B_FIBER)      : 1;

  // PE-row expected stage counts.
  // These constants document/align valid pipelines; they do not create latency
  // unless the corresponding RTL registers are implemented.
  parameter int LATCH_STAGES  = 1;
  parameter int MFIU_STAGES   = 3;
  parameter int DIST_STAGES   = 1;
  parameter int MUL_STAGES    = 1;
  parameter int TREE_STAGES   = 1;
  parameter int BUF_STAGES    = 1;
  parameter int PE_ROW_STAGES = LATCH_STAGES + MFIU_STAGES + DIST_STAGES
                              + MUL_STAGES + TREE_STAGES + BUF_STAGES;

  // Per-row output accumulation buffer.
  // LOCAL_BUF_DEPTH is provisional until output tile mapping and controller
  // writeback policy are finalized.
  parameter int N_BANK_LBUF     = 4;
  parameter int LOCAL_BUF_DEPTH = 512;
  parameter int LOCAL_BUF_AW    = (LOCAL_BUF_DEPTH > 1) ? $clog2(LOCAL_BUF_DEPTH) : 1;

endpackage : trapezoid_pkg
