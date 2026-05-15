# =============================================================================
# Makefile — Group 13 Final Project RTL build & test
# =============================================================================

RTL_DIR  := rtl
TB_DIR   := sim
PKG      := $(RTL_DIR)/trapezoid_pkg.sv

# 所有 RTL 檔 (top.sv + 各 module)
# 注意:merge_tree_radix16.sv owner = 黃妍心 + QuillQ,放 rtl/dist/。
#       它在 pe_row 內 instantiate (per-row,對齊 paper Fig 6,不是 global tree)。
RTL_SRCS := $(PKG) \
            $(RTL_DIR)/pe/mac_unit.sv \
            $(RTL_DIR)/pe/pe_row.sv \
            $(RTL_DIR)/pe/pe_array.sv \
            $(RTL_DIR)/mfiu/mfiu_top.sv \
            $(RTL_DIR)/dist/merge_tree_radix16.sv \
            $(RTL_DIR)/dist/merge_tree_radix16_sliced.sv \
            $(RTL_DIR)/dist/distribution_net.sv \
            $(RTL_DIR)/mem/global_buffer.sv \
            $(RTL_DIR)/ctrl/dataflow_ctrl.sv \
            $(RTL_DIR)/top.sv

IVERILOG := iverilog
VERILATOR := verilator

.PHONY: all tb_mac tb_tree tb_tree_sliced tb_pe_row tb_pe_array lint clean help

all: help

help:
	@echo "Targets:"
	@echo "  make tb_mac          — 跑 mac_unit 單元測試 (iverilog)"
	@echo "  make tb_tree         — 跑 merge_tree_radix16 單元測試 (single-tree mode)"
	@echo "  make tb_tree_sliced  — 跑 merge_tree_radix16_sliced 單元測試 (TrIP sub-tree slicing)"
	@echo "  make tb_pe_row       — 跑 pe_row 單元測試 (iverilog)"
	@echo "  make tb_pe_array     — 跑 pe_array 單元測試 (TODO,等 NoC 寫好再開)"
	@echo "  make lint            — Verilator lint 整個專案"
	@echo "  make clean           — 清掉 build artifact"

# ── mac_unit 單元測試 (iverilog) ──
tb_mac: $(RTL_DIR)/pe/mac_unit.sv $(TB_DIR)/tb_mac_unit.sv
	$(IVERILOG) -g2012 -o tb_mac.vvp \
		-I$(RTL_DIR) \
		$(RTL_DIR)/pe/mac_unit.sv \
		$(TB_DIR)/tb_mac_unit.sv
	vvp tb_mac.vvp

# ── merge_tree_radix16 單元測試 (iverilog) ──
tb_tree: $(PKG) $(RTL_DIR)/dist/merge_tree_radix16.sv $(TB_DIR)/tb_merge_tree.sv
	$(IVERILOG) -g2012 -o tb_tree.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/dist/merge_tree_radix16.sv \
		$(TB_DIR)/tb_merge_tree.sv
	vvp tb_tree.vvp

# ── merge_tree_radix16_sliced 單元測試 (iverilog) ──
# 測 TrIP sub-tree slicing(paper §III.B Fig 10 對應)
tb_tree_sliced: $(PKG) $(RTL_DIR)/dist/merge_tree_radix16_sliced.sv $(TB_DIR)/tb_merge_tree_sliced.sv
	$(IVERILOG) -g2012 -o tb_tree_sliced.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/dist/merge_tree_radix16_sliced.sv \
		$(TB_DIR)/tb_merge_tree_sliced.sv
	vvp tb_tree_sliced.vvp

# ── pe_row 單元測試 (iverilog) ──
# 依賴:trapezoid_pkg + mac_unit + merge_tree_radix16 + pe_row
tb_pe_row: $(PKG) \
           $(RTL_DIR)/pe/mac_unit.sv \
           $(RTL_DIR)/dist/merge_tree_radix16.sv \
           $(RTL_DIR)/pe/pe_row.sv \
           $(TB_DIR)/tb_pe_row.sv
	$(IVERILOG) -g2012 -o tb_pe_row.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/pe/mac_unit.sv \
		$(RTL_DIR)/dist/merge_tree_radix16.sv \
		$(RTL_DIR)/pe/pe_row.sv \
		$(TB_DIR)/tb_pe_row.sv
	vvp tb_pe_row.vvp

# ── pe_array 單元測試 (placeholder) ──
tb_pe_array:
	@echo "TODO: 寫 sim/tb_pe_array.sv,等 QuillQ 的 NoC (distribution_net) 寫好再開"
	@echo "      此 tb 會測 B forwarding chain 跟 16 條 row 同時跑 dot product"

# ── 全專案 lint (整合前必過) ──
lint:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSED -Wno-DECLFILENAME \
		-I$(RTL_DIR) \
		--top-module top \
		$(RTL_SRCS)

clean:
	rm -f *.vvp *.vcd
	rm -rf obj_dir
