# =============================================================================
# Makefile — Group 13 Final Project RTL build & test
# =============================================================================

RTL_DIR  := rtl
TB_DIR   := sim
PKG      := $(RTL_DIR)/trapezoid_pkg.sv

# 最終 PE row stack(lint 用;各單元測試 target 自列依賴)
# mfiu_adapter 內含交集核心 mfiu.v(楊承豫);dist_net_row 為 Dense identity crossbar,
# QuillQ 真版 NoC 到位後替換。
RTL_SRCS := $(PKG) \
            $(RTL_DIR)/pe/mac_unit.sv \
            $(RTL_DIR)/mfiu/mfiu.v \
            $(RTL_DIR)/mfiu/mfiu_adapter.sv \
            $(RTL_DIR)/dist/dist_net_row.sv \
            $(RTL_DIR)/dist/reduction_tree_radix16.sv \
            $(RTL_DIR)/pe/sram_128x32_1r1w.sv \
            $(RTL_DIR)/pe/local_buffer_row.sv \
            $(RTL_DIR)/pe/pe_row_full.sv

IVERILOG := iverilog
VERILATOR := verilator

.PHONY: all tb_mac tb_reduction_tree tb_lbuf tb_mfiu_adapter tb_dist_net tb_dist_net_trip tb_mfiu_mf_chain tb_pe_row_full tb_pe_array lint clean help

all: help

help:
	@echo "Targets:"
	@echo "  make tb_mac           — mac_unit 單元測試 (iverilog)"
	@echo "  make tb_reduction_tree — reduction_tree_radix16 單元測試 (sub-tree slicing)"
	@echo "  make tb_lbuf          — local_buffer_row 單元測試 (4-bank accumulator)"
	@echo "  make tb_mfiu_adapter      — mfiu_adapter 單元測試 (包 mfiu.v 交集核心; Dense + TrIP)"
	@echo "  make tb_dist_net      — dist_net_row 單元測試 (Dense identity)"
	@echo "  make tb_pe_row_full   — pe_row_full 端到端測試 (8-stage PE row)"
	@echo "  make tb_pe_array      — pe_array 端到端測試 (16×16, Dense IP vs A×B)"
	@echo "  make lint             — Verilator lint (top = pe_row_full)"
	@echo "  make clean            — 清掉 build artifact"

# ── mac_unit 單元測試 (iverilog) ──
tb_mac: $(RTL_DIR)/pe/mac_unit.sv $(TB_DIR)/tb_mac_unit.sv
	$(IVERILOG) -g2012 -o tb_mac.vvp \
		-I$(RTL_DIR) \
		$(RTL_DIR)/pe/mac_unit.sv \
		$(TB_DIR)/tb_mac_unit.sv
	vvp tb_mac.vvp

# ── reduction_tree_radix16 單元測試 (iverilog) ──
# Flexagon-style binary tree:cut_after 分段加總,組合邏輯 + 1 拍 output register
tb_reduction_tree: $(PKG) $(RTL_DIR)/dist/reduction_tree_radix16.sv $(TB_DIR)/tb_reduction_tree.sv
	$(IVERILOG) -g2012 -o tb_reduction_tree.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/dist/reduction_tree_radix16.sv \
		$(TB_DIR)/tb_reduction_tree.sv
	vvp tb_reduction_tree.vvp

# ── local_buffer_row 單元測試 (iverilog) ──
tb_lbuf: $(PKG) $(RTL_DIR)/pe/sram_128x32_1r1w.sv $(RTL_DIR)/pe/local_buffer_row.sv $(TB_DIR)/tb_local_buffer.sv
	$(IVERILOG) -g2012 -o tb_lbuf.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/pe/sram_128x32_1r1w.sv \
		$(RTL_DIR)/pe/local_buffer_row.sv \
		$(TB_DIR)/tb_local_buffer.sv
	vvp tb_lbuf.vvp

# ── mfiu_adapter 單元測試 (iverilog) ──
# 交集核心採用 mfiu.v(楊承豫);設為單 fiber pair × K=16,涵蓋 Dense + TrIP
tb_mfiu_adapter: $(PKG) $(RTL_DIR)/mfiu/mfiu.v $(RTL_DIR)/mfiu/mfiu_adapter.sv $(TB_DIR)/tb_mfiu_adapter.sv
	$(IVERILOG) -g2012 -o tb_mfiu_adapter.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/mfiu/mfiu.v \
		$(RTL_DIR)/mfiu/mfiu_adapter.sv \
		$(TB_DIR)/tb_mfiu_adapter.sv
	vvp tb_mfiu_adapter.vvp

# ── dist_net_row 單元測試 (iverilog) ──
# 介面 stand-in:Dense identity;真版 body 由 QuillQ 提供
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

# ── pe_row_full 端到端測試 (iverilog) ──
# 完整 PE row:A latch + MFIU + dist net + mul×16 + flexagon tree
#             + 16→4 壓縮 + 4-bank local buffer(SRAM wrapper)
tb_pe_row_full: $(PKG) \
                $(RTL_DIR)/pe/mac_unit.sv \
                $(RTL_DIR)/mfiu/mfiu.v \
                $(RTL_DIR)/mfiu/mfiu_adapter.sv \
                $(RTL_DIR)/dist/dist_net_row.sv \
                $(RTL_DIR)/dist/reduction_tree_radix16.sv \
                $(RTL_DIR)/pe/sram_128x32_1r1w.sv \
                $(RTL_DIR)/pe/local_buffer_row.sv \
                $(RTL_DIR)/pe/pe_row_full.sv \
                $(TB_DIR)/tb_pe_row_full.sv
	$(IVERILOG) -g2012 -o tb_pe_row_full.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/pe/mac_unit.sv \
		$(RTL_DIR)/mfiu/mfiu.v \
		$(RTL_DIR)/mfiu/mfiu_adapter.sv \
		$(RTL_DIR)/dist/dist_net_row.sv \
		$(RTL_DIR)/dist/reduction_tree_radix16.sv \
		$(RTL_DIR)/pe/sram_128x32_1r1w.sv \
		$(RTL_DIR)/pe/local_buffer_row.sv \
		$(RTL_DIR)/pe/pe_row_full.sv \
		$(TB_DIR)/tb_pe_row_full.sv
	vvp tb_pe_row_full.vvp

# ── pe_array 端到端測試 (iverilog) ──
# 16× pe_row_full + B 縱向鏈;Dense IP 對 A×B 驗證
tb_pe_array: $(PKG) \
             $(RTL_DIR)/pe/mac_unit.sv \
             $(RTL_DIR)/mfiu/mfiu.v \
             $(RTL_DIR)/mfiu/mfiu_adapter.sv \
             $(RTL_DIR)/dist/dist_net_row.sv \
             $(RTL_DIR)/dist/reduction_tree_radix16.sv \
             $(RTL_DIR)/pe/sram_128x32_1r1w.sv \
             $(RTL_DIR)/pe/local_buffer_row.sv \
             $(RTL_DIR)/pe/pe_row_full.sv \
             $(RTL_DIR)/pe/pe_array.sv \
             $(TB_DIR)/tb_pe_array.sv
	$(IVERILOG) -g2012 -o tb_pe_array.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/pe/mac_unit.sv \
		$(RTL_DIR)/mfiu/mfiu.v \
		$(RTL_DIR)/mfiu/mfiu_adapter.sv \
		$(RTL_DIR)/dist/dist_net_row.sv \
		$(RTL_DIR)/dist/reduction_tree_radix16.sv \
		$(RTL_DIR)/pe/sram_128x32_1r1w.sv \
		$(RTL_DIR)/pe/local_buffer_row.sv \
		$(RTL_DIR)/pe/pe_row_full.sv \
		$(RTL_DIR)/pe/pe_array.sv \
		$(TB_DIR)/tb_pe_array.sv
	vvp tb_pe_array.vvp

# ── 全專案 lint (整合前必過) ──
lint:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSED -Wno-DECLFILENAME \
		-I$(RTL_DIR) \
		--top-module pe_row_full \
		$(RTL_SRCS)

clean:
	rm -f *.vvp *.vcd
	rm -rf obj_dir
