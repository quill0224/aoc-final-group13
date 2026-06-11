# =============================================================================
# Makefile — Group 13 Final Project RTL build & test
# =============================================================================

RTL_DIR  := rtl
TB_DIR   := sim
PKG      := $(RTL_DIR)/trapezoid_pkg.sv

# 最終 PE row stack(lint 用;各單元測試 target 自列依賴)
# mfiu_row / dist_net_row 目前為介面相容的 Dense pass-through,
# 等真版(楊承豫 / QuillQ)到位後替換。
RTL_SRCS := $(PKG) \
            $(RTL_DIR)/pe/mac_unit.sv \
            $(RTL_DIR)/mfiu/mfiu_row.sv \
            $(RTL_DIR)/dist/dist_net_row.sv \
            $(RTL_DIR)/dist/merge_tree_radix16_flexagon.sv \
            $(RTL_DIR)/pe/sram_128x32_1r1w.sv \
            $(RTL_DIR)/pe/local_buffer_row.sv \
            $(RTL_DIR)/pe/pe_row_full.sv

IVERILOG := iverilog
VERILATOR := verilator

.PHONY: all tb_mac tb_tree_flexagon tb_lbuf tb_mfiu_row tb_dist_net tb_pe_row_full lint clean help

all: help

help:
	@echo "Targets:"
	@echo "  make tb_mac           — mac_unit 單元測試 (iverilog)"
	@echo "  make tb_tree_flexagon — merge_tree_radix16_flexagon 單元測試 (sub-tree slicing)"
	@echo "  make tb_lbuf          — local_buffer_row 單元測試 (4-bank accumulator)"
	@echo "  make tb_mfiu_row      — mfiu_row 單元測試 (Dense IP pass-through)"
	@echo "  make tb_dist_net      — dist_net_row 單元測試 (Dense identity)"
	@echo "  make tb_pe_row_full   — pe_row_full 端到端測試 (8-stage PE row)"
	@echo "  make lint             — Verilator lint (top = pe_row_full)"
	@echo "  make clean            — 清掉 build artifact"

# ── mac_unit 單元測試 (iverilog) ──
tb_mac: $(RTL_DIR)/pe/mac_unit.sv $(TB_DIR)/tb_mac_unit.sv
	$(IVERILOG) -g2012 -o tb_mac.vvp \
		-I$(RTL_DIR) \
		$(RTL_DIR)/pe/mac_unit.sv \
		$(TB_DIR)/tb_mac_unit.sv
	vvp tb_mac.vvp

# ── merge_tree_radix16_flexagon 單元測試 (iverilog) ──
# Flexagon-style binary tree:cut_after 分段加總,組合邏輯 + 1 拍 output register
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
# 介面 stand-in:Dense IP pass-through;真版 body 由楊承豫提供
tb_mfiu_row: $(PKG) $(RTL_DIR)/mfiu/mfiu_row.sv $(TB_DIR)/tb_mfiu_row.sv
	$(IVERILOG) -g2012 -o tb_mfiu_row.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/mfiu/mfiu_row.sv \
		$(TB_DIR)/tb_mfiu_row.sv
	vvp tb_mfiu_row.vvp

# ── dist_net_row 單元測試 (iverilog) ──
# 介面 stand-in:Dense identity;真版 body 由 QuillQ 提供
tb_dist_net: $(PKG) $(RTL_DIR)/dist/dist_net_row.sv $(TB_DIR)/tb_dist_net_row.sv
	$(IVERILOG) -g2012 -o tb_dist_net.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/dist/dist_net_row.sv \
		$(TB_DIR)/tb_dist_net_row.sv
	vvp tb_dist_net.vvp

# ── pe_row_full 端到端測試 (iverilog) ──
# 完整 PE row:A latch + MFIU + dist net + mul×16 + flexagon tree
#             + 16→4 壓縮 + 4-bank local buffer(SRAM wrapper)
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

# ── 全專案 lint (整合前必過) ──
lint:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSED -Wno-DECLFILENAME \
		-I$(RTL_DIR) \
		--top-module pe_row_full \
		$(RTL_SRCS)

clean:
	rm -f *.vvp *.vcd
	rm -rf obj_dir
