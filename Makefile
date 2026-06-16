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

.PHONY: clean help \
        controller0 run_controller \
        run_SRAM run_GLB run_DMA run_CTRL run_MC run_INTEGRATION run_unit_all

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Run targets — Unit Tests:"
	@echo "  run_SRAM                       - Run SRAM unit test"
	@echo "  run_GLB                        - Run GLB unit test"
	@echo "  run_DMA                        - Run DMA unit test"
	@echo "  run_CTRL                       - Run Controller unit test"
	@echo "  run_INTEGRATION                - Run HW Integration test"
	@echo "  run_unit_all                   - Run all unit tests sequentially"
	@echo ""
	@echo "Run targets — Standalone Controller (Jacky):"
	@echo "  run_controller                 - Build & Run standalone controller"
	@echo ""
	@echo "Clean targets:"
	@echo "  clean                          - Clean all build artifacts"
	@echo ""

# ============================================================
# Unit Test Targets (Delegating to tb/testbench/dla)
# ============================================================
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

# ============================================================
# controller - standalone test (no DLA dependency) Jacky
# ============================================================
CONTROLLER_TB_DIR := $(LAB4_ROOT)/test/testbench/dla
CONTROLLER_BUILD  := $(CONTROLLER_TB_DIR)/build_controller

controller0:
	$(call msg_grey,[ROOT] Building controller...)
	@mkdir -p test/testbench/dla/build_controller $(BUILD_DIR)/controller
	@verilator -Wall --cc --trace-fst --timing --top-module top_controller \
		-I$(LAB4_ROOT)/src/hardware/dla -I$(LAB4_ROOT)/src/hardware/dla/include -I$(LAB4_ROOT)/include \
		$(LAB4_ROOT)/src/hardware/dla/ASIC/top_controller.sv \
		--exe test/testbench/dla/tb_controller.cpp \
		-CFLAGS "-O2" --Mdir test/testbench/dla/build_controller -LDFLAGS "-lpthread" > /dev/null 2>&1
	@$(MAKE) -C test/testbench/dla/build_controller -f Vtop_controller.mk -j > /dev/null
	$(call msg_green,[ROOT] Controller ready)

run_controller: controller0
	$(call msg_cyan,[ROOT] Running controller...)
	@test/testbench/dla/build_controller/Vtop_controller
	@mv -f controller.fst $(BUILD_DIR)/controller/controller_$$(date +%m%d_%H%M%S).fst 2>/dev/null || true
	$(call msg_green,[ROOT] Waveform saved)

# ============================================================
# clean targets
# ============================================================
clean:
	$(call msg_grey,[ROOT] Cleaning artifacts...)
	@rm -rf $(BUILD_DIR)
	@$(MAKE) -C tb/testbench/dla clean
	$(call msg_green,[ROOT] Done.)
