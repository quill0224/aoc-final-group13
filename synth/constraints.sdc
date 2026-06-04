#==============================================================================
# constraints.sdc — 時序限制 (pe_row_full),由 synth.tcl source 進來
#==============================================================================
# 目標時脈 500 MHz = 週期 2.0 ns。第一次不用改,先看跑得過不過。
#==============================================================================

# ---------- clock ----------
create_clock -name clk -period 2.0 [get_ports clk]
set_clock_uncertainty 0.10 [get_clocks clk]      ;# 預留 jitter/skew
set_clock_latency     0.20 [get_clocks clk]

# ---------- I/O delay(抓週期 25% 當 budget)----------
set_input_delay  0.5 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 0.5 -clock clk [all_outputs]

# ---------- reset 不算時序路徑 ----------
set_false_path -from [get_ports rst_n]

# ---------- 輸出負載(粗估,先求能跑)----------
set_load 0.05 [all_outputs]

# 註:driving cell 要實際 cell 名稱,第一次不確定就先不設(留註解):
# set_driving_cell -lib_cell <BUFx2之類> [remove_from_collection [all_inputs] [get_ports clk]]
