// =============================================================================
// trapezoid_pkg.sv - PE engine parameters
// =============================================================================
// Defines the PE-array shape, datapath widths, MFIU batch size, pipeline
// latency, and per-row accumulation-buffer geometry. System-level protocol
// parameters and mode encoding are defined outside the PE engine.
// =============================================================================

package trapezoid_pkg;

  // 16 rows x 16 multiplier lanes.
  parameter int N_PE_ROW  = 16;
  parameter int N_MUL_ROW = 16;

  // Operand, product, and accumulator widths.
  parameter int DATA_W = 8;           // uint8 A / int8 B operand
  parameter int PROD_W = 2 * DATA_W;  // product width = 16
  parameter int ACC_W  = 32;          // partial-sum width

  // Maximum number of B columns offered to the MFIU per batch.
  parameter int N_B_FIBER = 4;

  // Width required to represent an active-lane count from 0 to N_MUL_ROW.
  parameter int LANE_COUNT_W = (N_MUL_ROW > 0) ? $clog2(N_MUL_ROW + 1) : 1;

  // Registered latency used by pe_row_tail for control alignment.
  parameter int MUL_STAGES  = 1;  // mac_unit registered latency
  parameter int TREE_STAGES = 1;  // reduction_tree_radix16 registered latency

  // Per-row partial-sum buffer.
  parameter int N_BANK_LBUF     = 4;
  parameter int LOCAL_BUF_DEPTH = 512;
  parameter int LOCAL_BUF_AW    = (LOCAL_BUF_DEPTH > 1) ? $clog2(LOCAL_BUF_DEPTH) : 1;

endpackage : trapezoid_pkg
