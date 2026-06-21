# =============================================================================
# Merged Makefile
# - Lab4 / DLA root targets
# - Group 13 RTL PE-row / PE-array unit tests
# =============================================================================

# =============================================================================
# Common / Lab4 root settings
# =============================================================================
LAB4_ROOT := $(abspath .)
BUILD_DIR := $(LAB4_ROOT)/build

RESET  := \033[0m
GREY   := \033[0;37m
WHITE  := \033[1;37m
GREEN  := \033[0;32m
RED    := \033[0;31m
CYAN   := \033[0;36m
YELLOW := \033[0;33m

define msg_grey
	@printf "$(GREY)$(1)$(RESET)\n"
endef
define msg_green
	@printf "$(GREEN)$(1)$(RESET)\n\n"
endef
define msg_red
	@printf "$(RED)$(1)$(RESET)\n"
endef
define msg_white
	@printf "$(WHITE)$(1)$(RESET)\n"
endef
define msg_cyan
	@printf "$(CYAN)$(1)$(RESET)\n"
endef
define msg_yellow
	@printf "$(YELLOW)$(1)$(RESET)\n"
endef
# =============================================================================
# Group 13 RTL settings
# Use G13_* prefix to avoid variable name collisions
# =============================================================================
G13_RTL_DIR  := rtl
G13_TB_DIR   := sim
G13_PKG      := $(G13_RTL_DIR)/trapezoid_pkg.sv

G13_RTL_SRCS := $(G13_PKG) \
                $(G13_RTL_DIR)/pe/mac_unit.sv \
                $(G13_RTL_DIR)/mfiu/mfiu.v \
                $(G13_RTL_DIR)/mfiu/mfiu_adapter.sv \
                $(G13_RTL_DIR)/dist/dist_net_row.sv \
                $(G13_RTL_DIR)/dist/reduction_tree_radix16.sv \
                $(G13_RTL_DIR)/pe/sram_128x32_1r1w.sv \
                $(G13_RTL_DIR)/pe/local_buffer_row.sv \
                $(G13_RTL_DIR)/pe/pe_row_full.sv

G13_IVERILOG := iverilog
G13_VERILATOR := verilator

# =============================================================================
# Phony targets
# =============================================================================
.PHONY: all clean help \
        controller0 run_controller \
        run_SRAM run_GLB run_DMA run_CTRL run_MC run_INTEGRATION run_unit_all \
        tb_mac tb_reduction_tree tb_lbuf tb_mfiu_adapter tb_dist_net \
        tb_dist_net_trip tb_mfiu_mf_chain \
        tb_pe_row_full tb_pe_array lint g13_clean
all: help

# =============================================================================
# Help
# =============================================================================
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Run targets — Lab4 / DLA Unit Tests:"
	@echo "  run_SRAM                         - Run SRAM unit test"
	@echo "  run_GLB                          - Run GLB unit test"
	@echo "  run_DMA                          - Run DMA unit test"
	@echo "  run_CTRL                         - Run Controller unit test"
	@echo "  run_MC                           - Run MC test"
	@echo "  run_INTEGRATION                  - Run HW Integration test"
	@echo "  run_unit_all                     - Run all unit tests sequentially"
	@echo ""
	@echo "Run targets — Standalone Controller:"
	@echo "  run_controller                   - Build & run standalone controller"
	@echo ""
	@echo "Run targets — Group 13 RTL PE Tests:"
	@echo "  tb_mac                           - mac_unit unit test, iverilog"
	@echo "  tb_reduction_tree                - reduction_tree_radix16 unit test"
	@echo "  tb_lbuf                          - local_buffer_row unit test"
	@echo "  tb_mfiu_adapter                  - mfiu_adapter unit test, Dense + TrIP"
	@echo "  tb_dist_net                      - dist_net_row unit test, Dense identity"
	@echo "  tb_pe_row_full                   - pe_row_full end-to-end test"
	@echo "  tb_dist_net_trip                 - dist_net_row_trip TrIP multi-fiber test"
	@echo "  tb_mfiu_mf_chain                 - mfiu_adapter_mf to dist_net_row_trip chain test"
	@echo "  tb_pe_array                      - pe_array end-to-end test, 16x16"
	@echo "  lint                             - Verilator lint, top = pe_row_full"
	@echo ""
	@echo "Clean targets:"
	@echo "  clean                            - Clean all build artifacts"
	@echo "  g13_clean                        - Clean Group 13 RTL artifacts only"
	@echo ""

# =============================================================================
# Lab4 / DLA Unit Test Targets
# Delegating to tb/testbench/dla
# =============================================================================
run_SRAM:
	$(call msg_grey,[ROOT] Delegating to DLA testbench for SRAM unit test...)
	@$(MAKE) -C tb/testbench/dla run_SRAM

run_GLB:
	$(call msg_grey,[ROOT] Delegating to DLA testbench for GLB unit test...)
	@$(MAKE) -C tb/testbench/dla run_GLB

run_DMA:
	$(call msg_grey,[ROOT] Delegating to DLA testbench for DMA unit test...)
	@$(MAKE) -C tb/testbench/dla run_DMA

run_CTRL:
	$(call msg_grey,[ROOT] Delegating to DLA testbench for CTRL unit test...)
	@$(MAKE) -C tb/testbench/dla run_CTRL

run_MC:
	$(call msg_grey,[ROOT] Delegating to DLA testbench for MC test...)
	@$(MAKE) -C tb/testbench/dla run_MC

run_INTEGRATION:
	$(call msg_grey,[ROOT] Delegating to DLA testbench for INTEGRATION test...)
	@$(MAKE) -C tb/testbench/dla run_INTEGRATION

run_unit_all:
	$(call msg_yellow,[ROOT] Running ALL Unit Tests sequentially...)
	@$(MAKE) -C tb/testbench/dla run_unit_all

# =============================================================================
# Standalone Controller Test
# =============================================================================
CONTROLLER_TB_DIR := $(LAB4_ROOT)/test/testbench/dla
CONTROLLER_BUILD  := $(CONTROLLER_TB_DIR)/build_controller

controller0:
	$(call msg_grey,[ROOT] Building controller...)
	@mkdir -p test/testbench/dla/build_controller $(BUILD_DIR)/controller
	@verilator -Wall --cc --trace-fst --timing --top-module top_controller \
		-I$(LAB4_ROOT)/src/hardware/dla \
		-I$(LAB4_ROOT)/src/hardware/dla/include \
		-I$(LAB4_ROOT)/include \
		$(LAB4_ROOT)/src/hardware/dla/ASIC/top_controller.sv \
		--exe test/testbench/dla/tb_controller.cpp \
		-CFLAGS "-O2" \
		--Mdir test/testbench/dla/build_controller \
		-LDFLAGS "-lpthread" > /dev/null 2>&1
	@$(MAKE) -C test/testbench/dla/build_controller -f Vtop_controller.mk -j > /dev/null
	$(call msg_green,[ROOT] Controller ready)

run_controller: controller0
	$(call msg_cyan,[ROOT] Running controller...)
	@test/testbench/dla/build_controller/Vtop_controller
	@mv -f controller.fst $(BUILD_DIR)/controller/controller_$$(date +%m%d_%H%M%S).fst 2>/dev/null || true
	$(call msg_green,[ROOT] Waveform saved)

# =============================================================================
# Group 13 RTL Tests
# =============================================================================

# -----------------------------------------------------------------------------
# mac_unit unit test
# -----------------------------------------------------------------------------
tb_mac: $(G13_RTL_DIR)/pe/mac_unit.sv $(G13_TB_DIR)/tb_mac_unit.sv
	$(G13_IVERILOG) -g2012 -o tb_mac.vvp \
		-I$(G13_RTL_DIR) \
		$(G13_RTL_DIR)/pe/mac_unit.sv \
		$(G13_TB_DIR)/tb_mac_unit.sv
	vvp tb_mac.vvp

# -----------------------------------------------------------------------------
# reduction_tree_radix16 unit test
# Flexagon-style binary tree:
# cut_after segmented summation, combinational logic + 1-cycle output register
# -----------------------------------------------------------------------------
tb_reduction_tree: $(G13_PKG) $(G13_RTL_DIR)/dist/reduction_tree_radix16.sv $(G13_TB_DIR)/tb_reduction_tree.sv
	$(G13_IVERILOG) -g2012 -o tb_reduction_tree.vvp \
		-I$(G13_RTL_DIR) \
		$(G13_PKG) \
		$(G13_RTL_DIR)/dist/reduction_tree_radix16.sv \
		$(G13_TB_DIR)/tb_reduction_tree.sv
	vvp tb_reduction_tree.vvp

# -----------------------------------------------------------------------------
# local_buffer_row unit test
# -----------------------------------------------------------------------------
tb_lbuf: $(G13_PKG) \
         $(G13_RTL_DIR)/pe/sram_128x32_1r1w.sv \
         $(G13_RTL_DIR)/pe/local_buffer_row.sv \
         $(G13_TB_DIR)/tb_local_buffer.sv
	$(G13_IVERILOG) -g2012 -o tb_lbuf.vvp \
		-I$(G13_RTL_DIR) \
		$(G13_PKG) \
		$(G13_RTL_DIR)/pe/sram_128x32_1r1w.sv \
		$(G13_RTL_DIR)/pe/local_buffer_row.sv \
		$(G13_TB_DIR)/tb_local_buffer.sv
	vvp tb_lbuf.vvp

# -----------------------------------------------------------------------------
# mfiu_adapter unit test
# Intersection core uses mfiu.v.
# One fiber pair x K=16, covering Dense + TrIP.
# -----------------------------------------------------------------------------
tb_mfiu_adapter: $(G13_PKG) \
                 $(G13_RTL_DIR)/mfiu/mfiu.v \
                 $(G13_RTL_DIR)/mfiu/mfiu_adapter.sv \
                 $(G13_TB_DIR)/tb_mfiu_adapter.sv
	$(G13_IVERILOG) -g2012 -o tb_mfiu_adapter.vvp \
		-I$(G13_RTL_DIR) \
		$(G13_PKG) \
		$(G13_RTL_DIR)/mfiu/mfiu.v \
		$(G13_RTL_DIR)/mfiu/mfiu_adapter.sv \
		$(G13_TB_DIR)/tb_mfiu_adapter.sv
	vvp tb_mfiu_adapter.vvp

# -----------------------------------------------------------------------------
# dist_net_row unit test
# Interface stand-in: Dense identity.
# Replace body later when real NoC arrives.
# -----------------------------------------------------------------------------
tb_dist_net: $(G13_PKG) \
             $(G13_RTL_DIR)/dist/dist_net_row.sv \
             $(G13_TB_DIR)/tb_dist_net_row.sv
	$(G13_IVERILOG) -g2012 -o tb_dist_net.vvp \
		-I$(G13_RTL_DIR) \
		$(G13_PKG) \
		$(G13_RTL_DIR)/dist/dist_net_row.sv \
		$(G13_TB_DIR)/tb_dist_net_row.sv
	vvp tb_dist_net.vvp

# -----------------------------------------------------------------------------
# dist_net_row_trip unit test
# TrIP multi-fiber 2D gather
# -----------------------------------------------------------------------------
tb_dist_net_trip: $(G13_PKG) \
                  $(G13_RTL_DIR)/dist/dist_net_row_trip.sv \
                  $(G13_TB_DIR)/tb_dist_net_row_trip.sv
	$(G13_IVERILOG) -g2012 -o tb_dist_net_trip.vvp \
		-I$(G13_RTL_DIR) \
		$(G13_PKG) \
		$(G13_RTL_DIR)/dist/dist_net_row_trip.sv \
		$(G13_TB_DIR)/tb_dist_net_row_trip.sv
	vvp tb_dist_net_trip.vvp

# -----------------------------------------------------------------------------
# Multi-fiber end-to-end chain
# mfiu_adapter_mf -> dist_net_row_trip
# -----------------------------------------------------------------------------
tb_mfiu_mf_chain: $(G13_PKG) \
                  $(G13_RTL_DIR)/mfiu/mfiu.v \
                  $(G13_RTL_DIR)/mfiu/mfiu_adapter_mf.sv \
                  $(G13_RTL_DIR)/dist/dist_net_row_trip.sv \
                  $(G13_TB_DIR)/tb_mfiu_mf_chain.sv
	$(G13_IVERILOG) -g2012 -o tb_mfiu_mf_chain.vvp \
		-I$(G13_RTL_DIR) \
		$(G13_PKG) \
		$(G13_RTL_DIR)/mfiu/mfiu.v \
		$(G13_RTL_DIR)/mfiu/mfiu_adapter_mf.sv \
		$(G13_RTL_DIR)/dist/dist_net_row_trip.sv \
		$(G13_TB_DIR)/tb_mfiu_mf_chain.sv
	vvp tb_mfiu_mf_chain.vvp

# -----------------------------------------------------------------------------
# pe_row_full end-to-end test
# Full PE row:
# A latch + MFIU + dist net + mul x16 + flexagon tree
# + 16-to-4 compression + 4-bank local buffer
# -----------------------------------------------------------------------------
tb_pe_row_full: $(G13_PKG) \
                $(G13_RTL_DIR)/pe/mac_unit.sv \
                $(G13_RTL_DIR)/mfiu/mfiu.v \
                $(G13_RTL_DIR)/mfiu/mfiu_adapter.sv \
                $(G13_RTL_DIR)/dist/dist_net_row.sv \
                $(G13_RTL_DIR)/dist/reduction_tree_radix16.sv \
                $(G13_RTL_DIR)/pe/sram_128x32_1r1w.sv \
                $(G13_RTL_DIR)/pe/local_buffer_row.sv \
                $(G13_RTL_DIR)/pe/pe_row_full.sv \
                $(G13_TB_DIR)/tb_pe_row_full.sv
	$(G13_IVERILOG) -g2012 -o tb_pe_row_full.vvp \
		-I$(G13_RTL_DIR) \
		$(G13_PKG) \
		$(G13_RTL_DIR)/pe/mac_unit.sv \
		$(G13_RTL_DIR)/mfiu/mfiu.v \
		$(G13_RTL_DIR)/mfiu/mfiu_adapter.sv \
		$(G13_RTL_DIR)/dist/dist_net_row.sv \
		$(G13_RTL_DIR)/dist/reduction_tree_radix16.sv \
		$(G13_RTL_DIR)/pe/sram_128x32_1r1w.sv \
		$(G13_RTL_DIR)/pe/local_buffer_row.sv \
		$(G13_RTL_DIR)/pe/pe_row_full.sv \
		$(G13_TB_DIR)/tb_pe_row_full.sv
	vvp tb_pe_row_full.vvp

# -----------------------------------------------------------------------------
# pe_array end-to-end test
# 16x pe_row_full + vertical B chain.
# Dense IP is verified against A x B.
# -----------------------------------------------------------------------------
tb_pe_array: $(G13_PKG) \
             $(G13_RTL_DIR)/pe/mac_unit.sv \
             $(G13_RTL_DIR)/mfiu/mfiu.v \
             $(G13_RTL_DIR)/mfiu/mfiu_adapter.sv \
             $(G13_RTL_DIR)/dist/dist_net_row.sv \
             $(G13_RTL_DIR)/dist/reduction_tree_radix16.sv \
             $(G13_RTL_DIR)/pe/sram_128x32_1r1w.sv \
             $(G13_RTL_DIR)/pe/local_buffer_row.sv \
             $(G13_RTL_DIR)/pe/pe_row_full.sv \
             $(G13_RTL_DIR)/pe/pe_array.sv \
             $(G13_TB_DIR)/tb_pe_array.sv
	$(G13_IVERILOG) -g2012 -o tb_pe_array.vvp \
		-I$(G13_RTL_DIR) \
		$(G13_PKG) \
		$(G13_RTL_DIR)/pe/mac_unit.sv \
		$(G13_RTL_DIR)/mfiu/mfiu.v \
		$(G13_RTL_DIR)/mfiu/mfiu_adapter.sv \
		$(G13_RTL_DIR)/dist/dist_net_row.sv \
		$(G13_RTL_DIR)/dist/reduction_tree_radix16.sv \
		$(G13_RTL_DIR)/pe/sram_128x32_1r1w.sv \
		$(G13_RTL_DIR)/pe/local_buffer_row.sv \
		$(G13_RTL_DIR)/pe/pe_row_full.sv \
		$(G13_RTL_DIR)/pe/pe_array.sv \
		$(G13_TB_DIR)/tb_pe_array.sv
	vvp tb_pe_array.vvp

# -----------------------------------------------------------------------------
# Group 13 RTL lint
# -----------------------------------------------------------------------------
lint:
	$(G13_VERILATOR) --lint-only -Wall -Wno-UNUSED -Wno-DECLFILENAME \
		-I$(G13_RTL_DIR) \
		--top-module pe_row_full \
		$(G13_RTL_SRCS)

# =============================================================================
# Clean targets
# =============================================================================

g13_clean:
	$(call msg_grey,[ROOT] Cleaning Group 13 RTL artifacts...)
	@rm -f *.vvp *.vcd
	@rm -rf obj_dir
	$(call msg_green,[ROOT] Group 13 RTL artifacts cleaned.)

clean:
	$(call msg_grey,[ROOT] Cleaning all artifacts...)
	@rm -rf $(BUILD_DIR)
	@rm -rf test/testbench/dla/build_controller
	@rm -f controller.fst
	@rm -f *.vvp *.vcd
	@rm -rf obj_dir
	@$(MAKE) -C tb/testbench/dla clean 2>/dev/null || true
	$(call msg_green,[ROOT] Done.)
.PHONY: sim_mfiu
sim_mfiu: $(G13_PKG) $(G13_RTL_DIR)/mfiu/mfiu.sv tb/tb_mfiu.cpp
	@mkdir -p build
	$(G13_VERILATOR) -Wall -Wno-UNUSEDPARAM --cc --exe --build -sv \
		-I$(G13_RTL_DIR) \
		$(G13_PKG) \
		$(G13_RTL_DIR)/mfiu/mfiu.sv \
		tb/tb_mfiu.cpp \
		--top-module mfiu \
		--Mdir build/mfiu_verilator
	./build/mfiu_verilator/Vmfiu
