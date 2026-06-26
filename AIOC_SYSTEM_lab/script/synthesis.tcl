set search_path [concat $search_path [list ../src ../include ../src/AXI ../src/NPU ../src/NPU/pe ../src/NPU/dist ../src/NPU/mfiu]]

analyze -format sverilog -define {USE_SRAM_MACRO} [list \
  ../src/NPU/trapezoid_pkg.sv \
  ../src/NPU/mfiu/mfiu.sv \
  ../src/NPU/dist/crossbar.sv \
  ../src/NPU/dist/reduction_tree_radix16.sv \
  ../src/NPU/pe/mac_unit.sv \
  ../src/NPU/pe/sram_128x32_1r1w.sv \
  ../src/NPU/pe/local_buffer_row.sv \
  ../src/NPU/pe/pe_row_tail.sv \
  ../src/NPU/pe/pe_mfiu_seq.sv \
  ../src/NPU/pe/pe_entry.sv \
  ../src/NPU/pe/pe_ab_buffer.sv \
  ../src/NPU/pe/pe_row.sv \
  ../src/NPU/pe/pe_array.sv \
  ../src/NPU/EPU_wrapper.sv \
  ../src/alu.sv \
  ../src/async_CDC_1.sv \
  ../src/async_CDC_16.sv \
  ../src/async_CDC_4.sv \
  ../src/branch_predictor.sv \
  ../src/CPU.sv \
  ../src/CPU_wrapper.sv \
  ../src/CSR.sv \
  ../src/DMA.sv \
  ../src/DMA_wrapper.sv \
  ../src/DM_cache.sv \
  ../src/DM_data_array_wrapper.sv \
  ../src/DM_tag_array_wrapper.sv \
  ../src/DRAM_FSM.sv \
  ../src/DRAM_wrapper.sv \
  ../src/easy_decoder.sv \
  ../src/Forward.sv \
  ../src/IM_cache.sv \
  ../src/IM_data_array_wrapper.sv \
  ../src/IM_tag_array_wrapper.sv \
  ../src/ins_decoder.sv \
  ../src/JB_Unit.sv \
  ../src/LD_filter.sv \
  ../src/mux0.sv \
  ../src/mux1.sv \
  ../src/mux11.sv \
  ../src/mux12.sv \
  ../src/mux2.sv \
  ../src/mux3.sv \
  ../src/mux4.sv \
  ../src/mux5.sv \
  ../src/mux6.sv \
  ../src/mux7.sv \
  ../src/mux8.sv \
  ../src/mux9.sv \
  ../src/mux_ad.sv \
  ../src/mux_jb.sv \
  ../src/ONE_CDC.sv \
  ../src/PC_reg.sv \
  ../src/reg1.sv \
  ../src/reg2.sv \
  ../src/reg3.sv \
  ../src/reg4.sv \
  ../src/reg_file.sv \
  ../src/reg_f_file.sv \
  ../src/reg_jb_pc.sv \
  ../src/ROM_wrapper.sv \
  ../src/SRAM_wrapper.sv \
  ../src/WDT.sv \
  ../src/WDT_wrapper.sv \
  ../src/AXI/AXI.sv \
  ../src/top.sv \
]

analyze -format verilog [list ../src/CHIP.v]

elaborate CHIP
link
uniquify
set_fix_multiple_port_nets -all -buffer_constants [get_designs *]

set hdlin_infer_mux true
set hdlin_infer_dff true
set hdlin_ff_always_sync_set_reset true
set hdlin_ff_always_async_set_reset true


set_host_options -max_core 16
source ../script/DC.sdc

set_max_leakage_power 0
compile_ultra -gate_clock -no_autoungroup
# optimize_registers
remove_unconnected_ports -blast_buses [get_cells * -hier]


set bus_inference_style {%s[%d]}
set bus_naming_style {%s[%d]}
set hdlout_internal_busses true

change_names -hierarchy -rule verilog

define_name_rules name_rule -allowed "A-Z a-z 0-9 _" -max_length 255 -type cell
define_name_rules name_rule -allowed "A-Z a-z 0-9 _[]" -max_length 255 -type net
define_name_rules name_rule -map {{"\\*cell\\*" "cell"}}
define_name_rules name_rule -case_insensitive
change_names -hierarchy -rules name_rule





write_file -format verilog -hier -output ../syn/CHIP_syn.v
write_sdf -version 2.1 -context verilog -load_delay net ../syn/CHIP_syn.sdf
report_timing > ../syn/timing.log
report_area > ../syn/area.log
report_power > ../syn/power.log

report_timing -path full -delay max -nworst 1 -max_paths 1 -significant_digits 2 -sort_by group > ../syn/timing_max_rpt.txt
report_timing -path full -delay min -nworst 1 -max_paths 1 -significant_digits 2 -sort_by group > ../syn/timing_min_rpt.txt

#exit



