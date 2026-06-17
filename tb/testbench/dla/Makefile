# =============================================================================
# tb/testbench/dla/Makefile
# Trapezoid-Lite ASIC Unit Test Runner (Fully Integrated)
# =============================================================================

CASE ?= case_SRAM

# ============================================================
# Path Definitions
# ============================================================
THIS_DIR := $(abspath .)
ROOT_DIR := $(abspath ../../..)
SRC_DIR := $(ROOT_DIR)/src
TESTS_DIR := $(abspath ../../tests)
CASE_DIR := $(TESTS_DIR)/$(CASE)

BUILD_DIR := $(THIS_DIR)/build
OBJ_DIR := $(BUILD_DIR)/$(CASE)_obj
RESULT_DIR := $(THIS_DIR)/results/fst

# ============================================================
# Terminal Colors
# ============================================================
RESET := \033[0m
GREY := \033[0;37m
GREEN := \033[0;32m
RED := \033[0;31m
CYAN := \033[0;36m
YELLOW := \033[0;33m

define msg_grey
	@printf "$(GREY)$(1)$(RESET)\n"
endef
define msg_green
	@printf "$(GREEN)$(1)$(RESET)\n\n"
endef
define msg_cyan
	@printf "$(CYAN)$(1)$(RESET)\n"
endef
define msg_yellow
	@printf "$(YELLOW)$(1)$(RESET)\n"
endef

# ============================================================
# Module Mapping
# ============================================================
ifeq ($(CASE), case_SRAM)
TOP_MODULE := SRAM_rtl
V_SRCS := $(SRC_DIR)/SRAM_rtl.sv

else ifeq ($(CASE), case_GLB)
TOP_MODULE := GLB
V_SRCS := $(SRC_DIR)/GLB.sv \
          $(SRC_DIR)/SRAM_rtl.sv

else ifeq ($(CASE), case_DMA)
TOP_MODULE := DMA
V_SRCS := $(SRC_DIR)/DMA.sv \
          $(SRC_DIR)/GLB.sv \
          $(SRC_DIR)/SRAM_rtl.sv

else ifeq ($(CASE), case_CTRL)
TOP_MODULE := top_controller
V_SRCS := $(SRC_DIR)/top_controller.sv

else ifeq ($(CASE), case_MC)
TOP_MODULE := MC
V_SRCS     := $(SRC_DIR)/MC.sv

else ifeq ($(CASE), case_INTEGRATION)
TOP_MODULE := top_integration
V_SRCS := $(SRC_DIR)/top_integration.sv \
          $(SRC_DIR)/top_controller.sv \
          $(SRC_DIR)/DMA.sv \
          $(SRC_DIR)/GLB.sv \
          $(SRC_DIR)/SRAM_rtl.sv \
          $(SRC_DIR)/axi_mem_model.sv \
          $(SRC_DIR)/MC.sv

else
$(error Unknown CASE=$(CASE). Valid: case_SRAM case_GLB case_DMA case_CTRL case_MC case_INTEGRATION)
endif

# ============================================================
# Verilator Flags
# ============================================================
VFLAGS := \
    --cc \
    --exe \
    --build \
    -j 0 \
    --trace-fst \
    -Wall \
    -Wno-fatal \
    -DSIMULATION \
    -I$(SRC_DIR)/AXI \
    -I$(SRC_DIR) \
    --top-module $(TOP_MODULE) \
    --Mdir $(OBJ_DIR)

# Single -CFLAGS with all options in one quoted group.
VCFLAGS := -CFLAGS \
    '-std=c++17 -I$(abspath $(THIS_DIR)) -I$(abspath $(CASE_DIR)) -I$(OBJ_DIR) -D$(CASE) -DRESULT_DIR=\"$(abspath $(RESULT_DIR))\"'

C_SRCS := \
    $(THIS_DIR)/tb.cpp \
    $(CASE_DIR)/workload.c \
    $(CASE_DIR)/main.c

# ============================================================
# Targets
# ============================================================
.PHONY: all build run clean help \
        run_SRAM run_GLB run_DMA run_CTRL run_MC run_INTEGRATION run_unit_all

all: run

build:
	$(call msg_grey,[$(CASE)] Verilating $(TOP_MODULE)...)
	@mkdir -p $(OBJ_DIR) $(RESULT_DIR)
	@verilator $(VFLAGS) $(VCFLAGS) $(V_SRCS) $(C_SRCS)
	$(call msg_green,[$(CASE)] Build OK → $(OBJ_DIR)/V$(TOP_MODULE))

run: build
	$(call msg_cyan,[$(CASE)] Running simulation...)
	@$(OBJ_DIR)/V$(TOP_MODULE)
	$(call msg_green,[$(CASE)] Done.)

# ============================================================
# Shortcut Targets
# ============================================================
run_SRAM:
	@$(MAKE) --no-print-directory run CASE=case_SRAM

run_GLB:
	@$(MAKE) --no-print-directory run CASE=case_GLB

run_DMA:
	@$(MAKE) --no-print-directory run CASE=case_DMA

run_CTRL:
	@$(MAKE) --no-print-directory run CASE=case_CTRL

run_MC:
	@$(MAKE) --no-print-directory run CASE=case_MC

run_INTEGRATION:
	@$(MAKE) --no-print-directory run CASE=case_INTEGRATION

run_unit_all:
	$(call msg_yellow,========================================)
	$(call msg_yellow,[DLA] Running all unit tests...)
	$(call msg_yellow,========================================)
	@$(MAKE) --no-print-directory run_SRAM && echo "" || exit 1
	@$(MAKE) --no-print-directory run_GLB && echo "" || exit 1
	@$(MAKE) --no-print-directory run_DMA && echo "" || exit 1
	@$(MAKE) --no-print-directory run_CTRL && echo "" || exit 1
	@$(MAKE) --no-print-directory run_MC && echo "" || exit 1
	@$(MAKE) --no-print-directory run_INTEGRATION && echo "" || exit 1
	$(call msg_green,[DLA] ALL UNIT TESTS PASSED)

# ============================================================
# Clean & Help
# ============================================================
clean:
	$(call msg_grey,[DLA] Cleaning...)
	@rm -rf $(BUILD_DIR) *.vcd *.fst
	$(call msg_green,[DLA] Clean done.)

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo " make run_SRAM        - SRAM_rtl unit test"
	@echo " make run_GLB         - GLB unit test"
	@echo " make run_DMA         - DMA fetch/writeback test"
	@echo " make run_CTRL        - top_controller FSM test"
	@echo " make run_MC          - MC AGU and latency test"
	@echo " make run_INTEGRATION - end-to-end system test"
	@echo " make run_unit_all    - run all cases sequentially"
	@echo " make run CASE=<name> - run a specific case"
	@echo " make clean           - remove all build artifacts"
