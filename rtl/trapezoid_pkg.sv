// =============================================================================
// trapezoid_pkg.sv -- PE row common parameters (live params only)
// =============================================================================
// Scope:
//   16x16 PE array, TrIP path. PE-row datapath widths, B-fiber sizing, and the
//   per-row output buffer. Packet/AXI/GLB params live outside rtl/pe.
//   Dataflow MODE encoding (Dense/TrIP) is NOT duplicated here: it lives in
//   ASIC.svh (the controller's source of truth); the PE array receives a 1-bit
//   TrIP-enable computed at the integration boundary.
// =============================================================================

package trapezoid_pkg;

  // PE array shape: 16 rows x 16 multiplier lanes = 256 MACs.
  parameter int N_PE_ROW  = 16;
  parameter int N_MUL_ROW = 16;

  // PE compute widths (DATA_W is the operand width, not the AXI/GLB bus width).
  parameter int DATA_W = 8;           // uint8 A / int8 B operand
  parameter int PROD_W = 2 * DATA_W;  // product width = 16
  parameter int ACC_W  = 32;          // partial-sum width

  // B-fiber group capacity: 1..N_B_FIBER columns dynamically packed per group.
  parameter int N_B_FIBER = 4;

  // Effectual-lane count width: counts 0..N_MUL_ROW, so needs clog2(N_MUL_ROW+1).
  parameter int LANE_COUNT_W = (N_MUL_ROW > 0) ? $clog2(N_MUL_ROW + 1) : 1;

  // Pipeline stage counts used to delay-align control in pe_row_tail:
  //   cut_after                          -> MUL_STAGES            (mac = 1 cycle)
  //   out_col / first_pass / cur_n_base  -> MUL_STAGES+TREE_STAGES (mac + tree)
  parameter int MUL_STAGES  = 1;  // mac_unit registered latency
  parameter int TREE_STAGES = 1;  // reduction_tree_radix16 registered latency

  // Per-row output (psum) accumulation buffer: N_BANK_LBUF banks, LOCAL_BUF_DEPTH total.
  parameter int N_BANK_LBUF     = 4;
  parameter int LOCAL_BUF_DEPTH = 512;
  parameter int LOCAL_BUF_AW    = (LOCAL_BUF_DEPTH > 1) ? $clog2(LOCAL_BUF_DEPTH) : 1;

endpackage : trapezoid_pkg
