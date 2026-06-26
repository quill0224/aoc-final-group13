// pe_engine.f -- elaboration/synthesis filelist for the standalone PE engine.
//
// Top module : pe_array   (Trapezoid-Lite 16x16 sparse-GEMM PE)
// Language   : SystemVerilog-2012. trapezoid_pkg must elaborate first.
//
// SRAM: by default sram_128x32_1r1w elaborates as a behavioral reg array
//   (large area, fine for a first synthesis pass). Define USE_SRAM_MACRO and
//   add the ADFP macro lib to bind the real 1R1W 128x32 macro instead.
//
// Self-contained: no external `include and no macros besides USE_SRAM_MACRO.
// (This is the bare compute engine; the SoC EPU_wrapper / AXI-S6 shell is separate.)

rtl/trapezoid_pkg.sv

rtl/mfiu/mfiu.sv
rtl/dist/crossbar.sv
rtl/dist/reduction_tree_radix16.sv

rtl/pe/mac_unit.sv
rtl/pe/sram_128x32_1r1w.sv
rtl/pe/local_buffer_row.sv
rtl/pe/pe_row_tail.sv
rtl/pe/pe_mfiu_seq.sv
rtl/pe/pe_entry.sv
rtl/pe/pe_ab_buffer.sv
rtl/pe/pe_row.sv
rtl/pe/pe_array.sv
