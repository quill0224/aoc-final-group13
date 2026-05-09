# =============================================================================
# Makefile — Group 13 Final Project RTL build & test
# =============================================================================

RTL_DIR  := rtl
TB_DIR   := sim
PKG      := $(RTL_DIR)/trapezoid_pkg.sv

# 所有 RTL 檔 (top.v + 各 module)
# 注意:merge tree 已從 rtl/dist/ 移到 rtl/pe/ (per-row,對齊 paper Fig 6)
RTL_SRCS := $(PKG) \
            $(RTL_DIR)/pe/mac_unit.v \
            $(RTL_DIR)/pe/merge_tree_radix16.v \
            $(RTL_DIR)/pe/pe_row.v \
            $(RTL_DIR)/pe/pe_array.v \
            $(RTL_DIR)/mfiu/mfiu_top.v \
            $(RTL_DIR)/dist/distribution_net.v \
            $(RTL_DIR)/mem/global_buffer.v \
            $(RTL_DIR)/ctrl/dataflow_ctrl.v \
            $(RTL_DIR)/top.v

IVERILOG := iverilog
VERILATOR := verilator

.PHONY: all tb_mac tb_pe_row tb_pe_array lint clean help

all: help

help:
	@echo "Targets:"
	@echo "  make tb_mac      — 跑 mac_unit 單元測試 (iverilog)"
	@echo "  make tb_pe_row   — 跑 pe_row 單元測試 (TODO 第 2 週寫)"
	@echo "  make tb_pe_array — 跑 pe_array 單元測試 (TODO 第 3 週寫)"
	@echo "  make lint        — Verilator lint 整個專案"
	@echo "  make clean       — 清掉 build artifact"

# ── mac_unit 單元測試 (iverilog) ──
tb_mac: $(RTL_DIR)/pe/mac_unit.v $(TB_DIR)/tb_mac_unit.sv
	$(IVERILOG) -g2012 -o tb_mac.vvp \
		-I$(RTL_DIR) \
		$(RTL_DIR)/pe/mac_unit.v \
		$(TB_DIR)/tb_mac_unit.sv
	vvp tb_mac.vvp

# ── pe_row 單元測試 (placeholder) ──
tb_pe_row:
	@echo "TODO Iris: 寫 sim/tb_pe_row.sv,測 16 個 mul 並排的 dot product"

# ── pe_array 單元測試 (placeholder) ──
tb_pe_array:
	@echo "TODO Iris: 寫 sim/tb_pe_array.sv,測整個 16x16 在 Dense IP 模式"

# ── 全專案 lint (整合前必過) ──
lint:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSED -Wno-DECLFILENAME \
		-I$(RTL_DIR) \
		--top-module top \
		$(RTL_SRCS)

clean:
	rm -f *.vvp *.vcd
	rm -rf obj_dir
