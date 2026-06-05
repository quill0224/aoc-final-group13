#==============================================================================
# constraints.sdc — 時序限制,由 synth.tcl source 進來(終版品質)
#   目標 500 MHz = 週期 2.0 ns。此 block 在 NPU 內部、同一 clock domain。
#==============================================================================

# ---------- clock ----------
create_clock -name clk -period 2.0 [get_ports clk]
set_clock_uncertainty 0.10 [get_clocks clk]      ;# jitter/skew 預留
set_clock_latency     0.20 [get_clocks clk]

# ---------- I/O delay(抓週期 25% 當 budget;留 50% = 1.0ns 給 block 內部)----------
set_input_delay  0.5 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 0.5 -clock clk [all_outputs]

# ---------- 輸入端 driving cell(synth.tcl 的 DRV_CELL 有填才設)----------
#   不設 = 理想驅動,input path 會偏樂觀;終版建議填真實 buffer。
if {[info exists DRV_CELL] && $DRV_CELL ne ""} {
    set_driving_cell -lib_cell $DRV_CELL \
        [remove_from_collection [all_inputs] [get_ports clk]]
}

# ---------- reset 不算時序路徑 ----------
set_false_path -from [get_ports rst_n]

# ---------- 輸出負載(粗估,先求能跑)----------
set_load 0.05 [all_outputs]

# 註:pre-layout 合成時 DC 用 lib 預設 wire load(先進製程多為 ZeroWireLoad,
#     線延遲要等 P&R 才進來),所以此階段 timing 偏樂觀屬正常,最終以 P&R 後為準。
