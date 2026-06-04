#==============================================================================
# synth.tcl — Synopsys Design Compiler 合成腳本 (Group 13 / pe_row_full)
#==============================================================================
# 跑法:   dc_shell -f synth/synth.tcl | tee synth/synth.log
#
# ★第一次只要填下面【現場填】的 2 個標準cell路徑★,其餘不用動。
#  (第一次跑 local_buffer 維持行為模型 mem 陣列,不需要 SRAM macro;
#   等之後把 buffer 改成 macro instantiate,再打開 SRAM 那兩行。)
#  路徑怎麼找 → docs/adfp-synth-handbook.md §3。
#==============================================================================

# ---------- 標準 cell library(superdome1 / N16ADFP,已填好)----------
set STDCELL_DB_DIR "/usr/cad/CBDK/Executable_Package/Collaterals/IP/stdcell/N16ADFP_StdCell/NLDM"
set STDCELL_DB     "N16ADFP_StdCelltt0p8v25c.db"   ;# typical, 0.8V, 25C

# ---------- SRAM macro(第二步:local_buffer 改成 macro 後,取消下面 2 行註解)----------
# set SRAM_DB_DIR  "/usr/cad/CBDK/Executable_Package/Collaterals/IP/sram/N16ADFP_SRAM/NLDM"
# set SRAM_DB      "N16ADFP_SRAM_tt0p8v0p8v25c_100a.db"

#==============================================================================
# 以下不用改
#==============================================================================
set TOP pe_row_full          ;# 先合單一 module;整顆要合時改成 top

# ---------- library ----------
set search_path    [concat "." $STDCELL_DB_DIR]
set target_library $STDCELL_DB
set link_library   "* $STDCELL_DB"
# 改用 SRAM macro 後改成下面這兩行:
#   set search_path  [concat "." $STDCELL_DB_DIR $SRAM_DB_DIR]
#   set link_library "* $STDCELL_DB $SRAM_DB"

# ---------- 讀 RTL ----------
# 只讀 pe_row_full 需要的 6 個檔(package 先);不 glob 整個資料夾,
# 避免掃到組員還沒寫好的 WIP(distribution_net / mfiu_top / 舊 pe_row…)
set RTL_FILES [list \
    rtl/trapezoid_pkg.sv \
    rtl/pe/mac_unit.sv \
    rtl/mfiu/mfiu_row.sv \
    rtl/dist/dist_net_row.sv \
    rtl/dist/merge_tree_radix16_flexagon.sv \
    rtl/pe/local_buffer_row.sv \
    rtl/pe/pe_row_full.sv ]
analyze -format sverilog $RTL_FILES
elaborate $TOP
current_design $TOP
link

# ---------- constraints ----------
source synth/constraints.sdc

# ---------- 合成 ----------
compile_ultra

# ---------- 報告 ----------
file mkdir reports
report_timing -max_paths 10 -delay_type max > reports/timing.rpt
report_area                                  > reports/area.rpt
report_power                                 > reports/power.rpt
report_qor                                   > reports/qor.rpt
write -format verilog -hierarchy -output reports/${TOP}_netlist.v

puts "=========================================="
puts " synth done → 看 reports/timing.rpt 的 slack"
puts "  slack 正數 = 過 500MHz;負數 = 不夠快"
puts "=========================================="
exit
