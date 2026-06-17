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
            $(RTL_DIR)/dist/merge_tree_radix16_flexagon.sv \
            $(RTL_DIR)/dist/distribution_net.sv \
            $(RTL_DIR)/mem/global_buffer.sv \
            $(RTL_DIR)/ctrl/dataflow_ctrl.sv \
            $(RTL_DIR)/top.sv

IVERILOG := iverilog
VERILATOR := verilator

.PHONY: all tb_mac tb_tree tb_tree_sliced tb_tree_flexagon tb_lbuf tb_mfiu_row tb_dist_net tb_dist_net_trip tb_pe_row tb_pe_row_full tb_pe_array tb_dist lint clean help

all: help

help:
	@echo "Targets:"
	@echo "  make tb_mac          — 跑 mac_unit 單元測試 (iverilog)"
	@echo "  make tb_tree         — 跑 merge_tree_radix16 單元測試 (single-tree mode)"
	@echo "  make tb_tree_sliced  — 跑 merge_tree_radix16_sliced 單元測試 (TrIP sub-tree slicing,Kogge-Stone variant)"
	@echo "  make tb_tree_flexagon — 跑 merge_tree_radix16_flexagon 單元測試 (Flexagon-style binary tree,1 cycle combinational)"
	@echo "  make tb_lbuf         — 跑 local_buffer_row 單元測試 (4-bank scatter buffer)"
	@echo "  make tb_mfiu_row     — 跑 mfiu_row 單元測試 (Dense IP pass-through)"
	@echo "  make tb_dist_net     — 跑 dist_net_row 單元測試 (Dense identity + TrIP routing)"
	@echo "  make tb_pe_row       — 跑 pe_row 單元測試 (iverilog)"
	@echo "  make tb_dist         — 跑 distribution_net Phase 1 pass-through 測試 (iverilog)"
	@echo "  make tb_pe_array     — 跑 pe_array 單元測試 (Dense IP + B chain)"
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

# ── merge_tree_radix16_flexagon 單元測試 (iverilog) ──
# 測 Flexagon-style binary tree(1 cycle combinational + output register)
# 對應 ASPLOS 2023 Flexagon paper Fig 4(b) node 設計 + Trapezoid §III.B sub-tree slicing
tb_tree_flexagon: $(PKG) $(RTL_DIR)/dist/merge_tree_radix16_flexagon.sv $(TB_DIR)/tb_merge_tree_flexagon.sv
	$(IVERILOG) -g2012 -o tb_tree_flexagon.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/dist/merge_tree_radix16_flexagon.sv \
		$(TB_DIR)/tb_merge_tree_flexagon.sv
	vvp tb_tree_flexagon.vvp

# ── local_buffer_row 單元測試 (iverilog) ──
tb_lbuf: $(PKG) $(RTL_DIR)/pe/sram_128x32_1r1w.sv $(RTL_DIR)/pe/local_buffer_row.sv $(TB_DIR)/tb_local_buffer.sv
	$(IVERILOG) -g2012 -o tb_lbuf.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/pe/sram_128x32_1r1w.sv \
		$(RTL_DIR)/pe/local_buffer_row.sv \
		$(TB_DIR)/tb_local_buffer.sv
	vvp tb_lbuf.vvp

# ── mfiu_row 單元測試 (iverilog) ──
# 介面 owner 黃妍心,Dense IP pass-through;TrIP body owner 劉偉健
tb_mfiu_row: $(PKG) $(RTL_DIR)/mfiu/mfiu_row.sv $(TB_DIR)/tb_mfiu_row.sv
	$(IVERILOG) -g2012 -o tb_mfiu_row.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/mfiu/mfiu_row.sv \
		$(TB_DIR)/tb_mfiu_row.sv
	vvp tb_mfiu_row.vvp

# ── dist_net_row 單元測試 (iverilog) ──
tb_dist_net: $(PKG) $(RTL_DIR)/dist/dist_net_row.sv $(TB_DIR)/tb_dist_net_row.sv
	$(IVERILOG) -g2012 -o tb_dist_net.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/dist/dist_net_row.sv \
		$(TB_DIR)/tb_dist_net_row.sv
	vvp tb_dist_net.vvp

# ── dist_net_row_trip 單元測試 (TrIP multi-fiber 2D gather, iverilog) ──
tb_dist_net_trip: $(PKG) $(RTL_DIR)/dist/dist_net_row_trip.sv $(TB_DIR)/tb_dist_net_row_trip.sv
	$(IVERILOG) -g2012 -o tb_dist_net_trip.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/dist/dist_net_row_trip.sv \
		$(TB_DIR)/tb_dist_net_row_trip.sv
	vvp tb_dist_net_trip.vvp

# ── 多 fiber 端到端串接 (mfiu_adapter_mf -> dist_net_row_trip, iverilog) ──
# 依賴楊的 rtl/mfiu/mfiu.v (整合分支上才有;本機測試需先拉過來)
tb_mfiu_mf_chain: $(PKG) $(RTL_DIR)/mfiu/mfiu.v $(RTL_DIR)/mfiu/mfiu_adapter_mf.sv \
                  $(RTL_DIR)/dist/dist_net_row_trip.sv $(TB_DIR)/tb_mfiu_mf_chain.sv
	$(IVERILOG) -g2012 -o tb_mfiu_mf_chain.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/mfiu/mfiu.v \
		$(RTL_DIR)/mfiu/mfiu_adapter_mf.sv \
		$(RTL_DIR)/dist/dist_net_row_trip.sv \
		$(TB_DIR)/tb_mfiu_mf_chain.sv
	vvp tb_mfiu_mf_chain.vvp

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

# ── distribution_net 單元測試 (iverilog) ──
# 依賴:trapezoid_pkg + distribution_net (純組合 0 cycle，無需其他 module)
# Phase 1 範圍:dense identity pass-through (6 個 test cases)
tb_dist: $(PKG) $(RTL_DIR)/dist/distribution_net.sv $(TB_DIR)/tb_distribution_net.sv
	$(IVERILOG) -g2012 -o tb_dist.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/dist/distribution_net.sv \
		$(TB_DIR)/tb_distribution_net.sv
	vvp tb_dist.vvp

# ── pe_row_full 端到端測試 (iverilog) ──
# 完整 PE row:A latch + MFIU + dist net + mul×16 + flexagon tree + local buffer
tb_pe_row_full: $(PKG) \
                $(RTL_DIR)/pe/mac_unit.sv \
                $(RTL_DIR)/mfiu/mfiu_row.sv \
                $(RTL_DIR)/dist/dist_net_row.sv \
                $(RTL_DIR)/dist/merge_tree_radix16_flexagon.sv \
                $(RTL_DIR)/pe/sram_128x32_1r1w.sv \
                $(RTL_DIR)/pe/local_buffer_row.sv \
                $(RTL_DIR)/pe/pe_row_full.sv \
                $(TB_DIR)/tb_pe_row_full.sv
	$(IVERILOG) -g2012 -o tb_pe_row_full.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/pe/mac_unit.sv \
		$(RTL_DIR)/mfiu/mfiu_row.sv \
		$(RTL_DIR)/dist/dist_net_row.sv \
		$(RTL_DIR)/dist/merge_tree_radix16_flexagon.sv \
		$(RTL_DIR)/pe/sram_128x32_1r1w.sv \
		$(RTL_DIR)/pe/local_buffer_row.sv \
		$(RTL_DIR)/pe/pe_row_full.sv \
		$(TB_DIR)/tb_pe_row_full.sv
	vvp tb_pe_row_full.vvp

# ── pe_array 單元測試 (iverilog) ──
# 依賴:trapezoid_pkg + mac_unit + merge_tree_radix16(舊版 single tree)+ pe_row + pe_array
# 測:Dense IP K=1/K=2 + B forwarding chain + A row-stationary
# 不測:TrIP sub-tree slicing(等 pe_row 換接 merge_tree_radix16_sliced 再加)
tb_pe_array: $(PKG) \
             $(RTL_DIR)/pe/mac_unit.sv \
             $(RTL_DIR)/dist/merge_tree_radix16.sv \
             $(RTL_DIR)/pe/pe_row.sv \
             $(RTL_DIR)/pe/pe_array.sv \
             $(TB_DIR)/tb_pe_array.sv
	$(IVERILOG) -g2012 -o tb_pe_array.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/pe/mac_unit.sv \
		$(RTL_DIR)/dist/merge_tree_radix16.sv \
		$(RTL_DIR)/pe/pe_row.sv \
		$(RTL_DIR)/pe/pe_array.sv \
		$(TB_DIR)/tb_pe_array.sv
	vvp tb_pe_array.vvp

# ── 全專案 lint (整合前必過) ──
lint:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSED -Wno-DECLFILENAME \
		-I$(RTL_DIR) \
		--top-module top \
		$(RTL_SRCS)

clean:
	rm -f *.vvp *.vcd
	rm -rf obj_dir
