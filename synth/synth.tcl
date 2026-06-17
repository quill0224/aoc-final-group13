#==============================================================================
# synth.tcl — Synopsys Design Compiler 合成腳本 (Group 13)
#   終版品質 flow:預設 TOP=pe_row_full(macro 模式),含 check_design/
#   check_timing、constraint 違反報告、netlist+ddc+sdc handoff。
#   要合別的模組:用環境變數 TOP 覆蓋(見下方跑法)。
#==============================================================================
# 跑法:
#   dc_shell -f synth/synth.tcl | tee synth/synth.log               ;# 合 pe_row_full(預設)
#   setenv TOP local_buffer_row ; dc_shell -f synth/synth.tcl ...    ;# 換目標(csh/tcsh)
#   TOP=mac_unit dc_shell -f synth/synth.tcl ...                     ;# 換目標(bash)
#
# 路徑/找 macro 方法 → docs/adfp-synth-handbook.md。
#==============================================================================

# ---------- 標準 cell library(superdome1 / N16ADFP)----------
set STDCELL_DB_DIR "/usr/cad/CBDK/Executable_Package/Collaterals/IP/stdcell/N16ADFP_StdCell/NLDM"
set STDCELL_DB     "N16ADFP_StdCelltt0p8v25c.db"          ;# typical, 0.8V, 25C

# ---------- SRAM macro(.db;macro 模式需要)----------
set SRAM_DB_DIR    "/usr/cad/CBDK/Executable_Package/Collaterals/IP/sram/N16ADFP_SRAM/NLDM"
set SRAM_DB        "N16ADFP_SRAM_tt0p8v0p8v25c_100a.db"

# ---------- 輸入端 driving cell(終版:設真實 buffer;留空=理想驅動,input path 偏樂觀)----------
#   找名稱:dc_shell 裡 →  get_lib_cells */*BUF*    挑一個中等驅動的 buffer 填進來
set DRV_CELL ""

#==============================================================================
# 目標模組:預設 pe_row_full;可用環境變數 TOP 覆蓋
#==============================================================================
if {[info exists ::env(TOP)] && $::env(TOP) ne ""} {
    set TOP $::env(TOP)
} else {
    set TOP pe_row_full
}
puts "### synth TOP = $TOP ###"

# 多核加速 compile(license 不支援就自動略過,不會中斷)
catch {set_host_options -max_cores 4}

# ---------- library(含 SRAM macro 的 .db)----------
set search_path    [concat "." $STDCELL_DB_DIR $SRAM_DB_DIR]
set target_library $STDCELL_DB
set link_library   "* $STDCELL_DB $SRAM_DB"

# ---------- 讀 RTL ----------
#   只讀 pe_row_full 需要的檔(package 先);不 glob 整資料夾,避免掃到 WIP。
#   mfiu_adapter 內含交集核心 mfiu.v(楊承豫);dist_net_row 為 Dense identity
#      crossbar(QuillQ 真版 NoC 到位後替換),其餘不動。
set RTL_FILES [list \
    rtl/trapezoid_pkg.sv \
    rtl/pe/mac_unit.sv \
    rtl/mfiu/mfiu.v \
    rtl/mfiu/mfiu_adapter.sv \
    rtl/dist/dist_net_row.sv \
    rtl/dist/dist_net_row_trip.sv \
    rtl/dist/reduction_tree_radix16.sv \
    rtl/pe/sram_128x32_1r1w.sv \
    rtl/pe/local_buffer_row.sv \
    rtl/pe/pe_row_full.sv ]
#   dist_net_row_trip.sv:TrIP multi-fiber 2D gather(純邏輯,對 pe_row_full 無影響)。
#   單獨驗 timing:  TOP=dist_net_row_trip dc_shell -f synth/synth.tcl | tee synth/trip.log
#   看 reports/dist_net_row_trip/{violators,timing_setup,qor}.rpt(64-to-1 mux 過不過 500MHz)

# macro 模式:-define USE_SRAM_MACRO → sram wrapper 接真 macro(非 behavioral flop)
analyze -format sverilog -define {USE_SRAM_MACRO} $RTL_FILES
elaborate $TOP
current_design $TOP
link

# ---------- 報告目錄(依 TOP 分開,避免不同模組互蓋)----------
set RPT reports/$TOP
file mkdir $RPT

# ---------- 結構檢查(unresolved ref / 多重驅動 / 浮接 port)----------
check_design > $RPT/check_design.rpt

# ---------- constraints ----------
source synth/constraints.sdc

# ---------- 時序限制完整性檢查(有沒有沒被限制到的 endpoint)----------
check_timing > $RPT/check_timing.rpt

# ---------- 合成 ----------
compile_ultra

# ---------- 報告 ----------
report_timing -max_paths 10 -delay_type max  > $RPT/timing_setup.rpt
report_timing -max_paths 10 -delay_type min  > $RPT/timing_hold.rpt   ;# 參考用:hold 在合成階段不準,P&R 才修
report_constraint -all_violators             > $RPT/violators.rpt     ;# ★最關鍵:有沒有違反任何限制
report_area  -hierarchy                      > $RPT/area.rpt
report_power -hierarchy                      > $RPT/power.rpt
report_qor                                   > $RPT/qor.rpt
report_reference -hierarchy                  > $RPT/reference.rpt      ;# 各 cell/macro 用幾顆(確認 Macro Count)

# ---------- handoff:給 P&R 用的 netlist + 資料庫 + 限制 ----------
write -format verilog -hierarchy -output $RPT/${TOP}_netlist.v
write -format ddc     -hierarchy -output $RPT/${TOP}.ddc
write_sdc                                  $RPT/${TOP}.sdc

puts "=========================================="
puts " synth done: TOP=$TOP → reports 在 $RPT/"
puts "  1) violators.rpt    : 應該是空的(出現 VIOLATED = 沒過)"
puts "  2) timing_setup.rpt : slack 正數 = 過 500MHz"
puts "  3) qor.rpt          : Critical Path Slack / Cell Area / Macro Count"
puts "  4) check_timing.rpt : 確認沒有 unconstrained 路徑"
puts "=========================================="
exit
