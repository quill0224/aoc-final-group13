root_dir := $(PWD)
src_dir := ./src
syn_dir := ./syn
# pr_dir := ./pr/icc2_ADFP_tsri/run
pr_dir := "./APR_new/innovus_stylus/APR"
inc_dir := ./include
sim_dir := ./sim
vip_dir := $(PWD)/vip
bld_dir := ./build
lib_dir := /usr/cad/CBDK/Executable_Package/Collaterals/IP/stdcell/N16ADFP_StdCell/VERILOG
lib_dir_io := /usr/cad/CBDK/Executable_Package/Collaterals/IP/stdio/N16ADFP_StdIO/VERILOG

export VCS_HOME := $(shell dirname $(shell dirname $(shell which vcs)))
FSDB_DEF :=
ifeq ($(FSDB),1)
FSDB_DEF := +FSDB
else ifeq ($(FSDB),2)
FSDB_DEF := +FSDB_ALL
endif
maxpend :=
ifeq ($(pend),1)
	maxpend := 1
else ifeq ($(pend),2) 
	maxpend := 2
else
	maxpend := 0
endif
$(info maxpend=$(maxpend))

export vip_dir
export maxpend

$(bld_dir):
	mkdir -p $(bld_dir)

$(syn_dir):
	mkdir -p $(syn_dir)

$(pr_dir):
	mkdir -p $(pr_dir)

$(bld_dir):
	mkdir -p $(bld_dir)
# AXI simulation
vip_b: clean | $(bld_dir)
	cd $(bld_dir); \
	jg ../script/jg_bridge.tcl &

# TA use this to check result
TA_run: 
  
# RTL simulation
rtl_all: rtl0 rtl1 rtl2 rtl3 rtl4

rtl0: | clean $(bld_dir)
	cd $(bld_dir); \
	vcs -R -sverilog $(root_dir)/$(sim_dir)/top_tb.sv -debug_access+all -full64 -debug_region+cell +memcbk \
	+incdir+$(root_dir)/$(src_dir)+$(root_dir)/$(src_dir)/AXI+$(root_dir)/$(inc_dir)+$(root_dir)/$(sim_dir) \
	-f $(root_dir)/$(src_dir)/rtl_sim.f \
	+define+prog0$(FSDB_DEF) \
	+prog_path=$(root_dir)/$(sim_dir)/prog0 \
  	+rdcycle=1 \
	+notimingcheck

rtl1: | clean $(bld_dir)
	cd $(bld_dir); \
	vcs -R -sverilog $(root_dir)/$(sim_dir)/top_tb.sv -debug_access+all -full64 -debug_region+cell +memcbk \
	+incdir+$(root_dir)/$(src_dir)+$(root_dir)/$(src_dir)/AXI+$(root_dir)/$(inc_dir)+$(root_dir)/$(sim_dir) \
	-f $(root_dir)/$(src_dir)/rtl_sim.f \
	+define+prog1$(FSDB_DEF) \
	+prog_path=$(root_dir)/$(sim_dir)/prog1 \
	+rdcycle=1 \
	+notimingcheck

rtl2: | clean $(bld_dir)
	cd $(bld_dir); \
	vcs -R -sverilog $(root_dir)/$(sim_dir)/top_tb.sv -debug_access+all -full64 -debug_region+cell +memcbk \
	+incdir+$(root_dir)/$(src_dir)+$(root_dir)/$(src_dir)/AXI+$(root_dir)/$(inc_dir)+$(root_dir)/$(sim_dir) \
	-f $(root_dir)/$(src_dir)/rtl_sim.f \
	+define+prog2$(FSDB_DEF) \
	+prog_path=$(root_dir)/$(sim_dir)/prog2 \
	+rdcycle=1 \
	+notimingcheck

rtl3: | clean $(bld_dir)
	cd $(bld_dir); \
	vcs -R -sverilog $(root_dir)/$(sim_dir)/top_tb_WDT.sv -debug_access+all -full64 -debug_region+cell +memcbk \
	+incdir+$(root_dir)/$(src_dir)+$(root_dir)/$(src_dir)/AXI+$(root_dir)/$(inc_dir)+$(root_dir)/$(sim_dir) \
	-f $(root_dir)/$(src_dir)/rtl_sim.f \
	+define+prog3$(FSDB_DEF) \
	+prog_path=$(root_dir)/$(sim_dir)/prog3 \
	+rdcycle=1 \
	+notimingcheck

rtl4: | clean $(bld_dir)
	cd $(bld_dir); \
	vcs -R -sverilog $(root_dir)/$(sim_dir)/top_tb.sv -debug_access+all -full64 -debug_region+cell +memcbk \
	+incdir+$(root_dir)/$(src_dir)+$(root_dir)/$(src_dir)/AXI+$(root_dir)/$(inc_dir)+$(root_dir)/$(sim_dir) \
	-f $(root_dir)/$(src_dir)/rtl_sim.f \
	+define+prog4$(FSDB_DEF) \
	+prog_path=$(root_dir)/$(sim_dir)/prog4 \
	+rdcycle=1 \
	+notimingcheck

# hough and love simulation targets removed (EPU modules removed)

# Post-Synthesis simulation
syn_all: syn0 syn1 syn2 syn3 syn4


syn0: | clean $(bld_dir)
	cd $(bld_dir); \
	vcs -R -sverilog +neg_tchk -negdelay +nospecify +notimingcheck -v $(lib_dir)/N16ADFP_StdCell.v  $(root_dir)/$(sim_dir)/top_tb.sv -debug_access+all -full64 -diag=sdf:verbose \
	+incdir+$(root_dir)/$(syn_dir)+$(root_dir)/$(inc_dir)+$(root_dir)/$(sim_dir) \
	+define+SYN+prog0$(FSDB_DEF) \
	+no_notifier \
	+prog_path=$(root_dir)/$(sim_dir)/prog0 \
  +rdcycle=1


syn1: | clean $(bld_dir)
	cd $(bld_dir); \
	vcs -R -sverilog +neg_tchk -negdelay +nospecify +notimingcheck -v $(lib_dir)/N16ADFP_StdCell.v  $(root_dir)/$(sim_dir)/top_tb.sv -debug_access+all -full64 -diag=sdf:verbose \
	+incdir+$(root_dir)/$(syn_dir)+$(root_dir)/$(inc_dir)+$(root_dir)/$(sim_dir) \
	+define+SYN+prog1$(FSDB_DEF) \
	+no_notifier \
	+prog_path=$(root_dir)/$(sim_dir)/prog1 \
  +rdcycle=1

syn2: | clean $(bld_dir)
	cd $(bld_dir); \
	vcs -R -sverilog +neg_tchk -negdelay +nospecify +notimingcheck -v $(lib_dir)/N16ADFP_StdCell.v  $(root_dir)/$(sim_dir)/top_tb.sv -debug_access+all -full64 -diag=sdf:verbose \
	+incdir+$(root_dir)/$(syn_dir)+$(root_dir)/$(inc_dir)+$(root_dir)/$(sim_dir) \
	+define+SYN+prog2$(FSDB_DEF) \
	+no_notifier \
	+prog_path=$(root_dir)/$(sim_dir)/prog2 \





syn3: | clean $(bld_dir)
	cd $(bld_dir); \
	vcs -R -sverilog +neg_tchk -negdelay +nospecify +notimingcheck -v $(lib_dir)/N16ADFP_StdCell.v  $(root_dir)/$(sim_dir)/top_tb_WDT.sv -debug_access+all -full64 -diag=sdf:verbose \
	+incdir+$(root_dir)/$(syn_dir)+$(root_dir)/$(inc_dir)+$(root_dir)/$(sim_dir) \
	+define+SYN+prog3$(FSDB_DEF) \
	+no_notifier \
	+prog_path=$(root_dir)/$(sim_dir)/prog3 \

syn4: | clean $(bld_dir)
	cd $(bld_dir); \
	vcs -R -sverilog +neg_tchk -negdelay +nospecify +notimingcheck -v $(lib_dir)/N16ADFP_StdCell.v  $(root_dir)/$(sim_dir)/top_tb.sv -debug_access+all -full64 -diag=sdf:verbose \
	+incdir+$(root_dir)/$(syn_dir)+$(root_dir)/$(inc_dir)+$(root_dir)/$(sim_dir) \
	+define+SYN+prog4$(FSDB_DEF) \
	+no_notifier \
	+prog_path=$(root_dir)/$(sim_dir)/prog4 \
  +rdcycle=1


# Post-Layout simulation
pr_all: pr0 pr1 pr2 pr3 pr4

pr0: | clean $(bld_dir)
	cd $(bld_dir); \
	vcs -R -sverilog +neg_tchk -negdelay +nospecify +notimingcheck +delay_mode_zero -v $(lib_dir)/N16ADFP_StdCell.v  $(root_dir)/$(sim_dir)/top_tb.sv -debug_access+all -full64 -diag=sdf:verbose \
	+incdir+$(root_dir)/$(pr_dir)+$(root_dir)/$(inc_dir)+$(root_dir)/$(sim_dir) \
	+define+PR+prog0$(FSDB_DEF) \
	+no_notifier \
	+maxdelays \
	+prog_path=$(root_dir)/$(sim_dir)/prog0 \

pr1: | clean $(bld_dir)
	cd $(bld_dir); \
	vcs -R -sverilog +neg_tchk -negdelay +nospecify +notimingcheck +delay_mode_zero -v $(lib_dir)/N16ADFP_StdCell.v  $(root_dir)/$(sim_dir)/top_tb.sv -debug_access+all -full64 -diag=sdf:verbose \
	+incdir+$(root_dir)/$(pr_dir)+$(root_dir)/$(inc_dir)+$(root_dir)/$(sim_dir) \
	+define+PR+prog1$(FSDB_DEF) \
	+no_notifier \
	+maxdelays \
	+prog_path=$(root_dir)/$(sim_dir)/prog1 \

pr2: | clean $(bld_dir)
	cd $(bld_dir); \
	vcs -R -sverilog +neg_tchk -negdelay +nospecify +notimingcheck +delay_mode_zero -v $(lib_dir)/N16ADFP_StdCell.v  $(root_dir)/$(sim_dir)/top_tb.sv -debug_access+all -full64 -diag=sdf:verbose \
	+incdir+$(root_dir)/$(pr_dir)+$(root_dir)/$(inc_dir)+$(root_dir)/$(sim_dir) \
	+define+PR+prog2$(FSDB_DEF) \
	+no_notifier \
	+maxdelays \
	+prog_path=$(root_dir)/$(sim_dir)/prog2 \

pr3: | clean $(bld_dir)
	cd $(bld_dir); \
	vcs -R -sverilog +neg_tchk -negdelay +nospecify +notimingcheck +delay_mode_zero -v $(lib_dir)/N16ADFP_StdCell.v  $(root_dir)/$(sim_dir)/top_tb_WDT.sv -debug_access+all -full64 -diag=sdf:verbose \
	+incdir+$(root_dir)/$(pr_dir)+$(root_dir)/$(inc_dir)+$(root_dir)/$(sim_dir) \
	+define+PR+prog3$(FSDB_DEF) \
	+no_notifier \
	+maxdelays \
	+prog_path=$(root_dir)/$(sim_dir)/prog3 \

pr4: | clean $(bld_dir)
	cd $(bld_dir); \
	vcs -R -sverilog +neg_tchk -negdelay +nospecify +notimingcheck +delay_mode_zero -v $(lib_dir)/N16ADFP_StdCell.v  $(root_dir)/$(sim_dir)/top_tb.sv -debug_access+all -full64 -diag=sdf:verbose \
	+incdir+$(root_dir)/$(pr_dir)+$(root_dir)/$(inc_dir)+$(root_dir)/$(sim_dir) \
	+define+PR+prog4$(FSDB_DEF) \
	+no_notifier \
	+maxdelays \
	+prog_path=$(root_dir)/$(sim_dir)/prog4 \


# Utilities
nWave: | $(bld_dir)
	cd $(bld_dir); \
	nWave chip.fsdb &

verdi: | $(bld_dir)
	cd $(bld_dir); \
	verdi -ssf top.fsdb &

superlint: | $(bld_dir)
	cd $(bld_dir); \
	jg -superlint ../script/superlint.tcl &

dv: | $(bld_dir) $(syn_dir)
	cp script/synopsys_dc.setup $(bld_dir)/.synopsys_dc.setup; \
	cd $(bld_dir); \
	dc_shell -gui -no_home_init &

synthesize: | $(bld_dir) $(syn_dir)
	cp script/synopsys_dc.setup $(bld_dir)/.synopsys_dc.setup; \
	cd $(bld_dir); \
	dc_shell -no_home_init -f ../script/synthesis.tcl | tee syn_compile.log

innovus: | $(bld_dir) $(pr_dir)
	cd $(bld_dir); \
	innovus

icc2: | $(pr_dir)
	make clean_pr; \
	cd $(pr_dir); \
	icc2_shell -file ../scripts/00_run.tcl

icc2_gui: | $(pr_dir)
	cd $(pr_dir); \
	icc2_shell -gui;

spyglass: | $(bld_dir)
	cd $(bld_dir); \
	spyglass -tcl ../script/Spyglass_CDC.tcl &

# Check file structure
BLUE=\033[1;34m
RED=\033[1;31m
NORMAL=\033[0m

check: clean
	@echo "Check bypassed: StudentID settings removed."

tar: check
	FOLDER_NAME=$$(basename $(PWD)); \
	cd ..; \
	tar cvf $$FOLDER_NAME.tar $$FOLDER_NAME

.PHONY: clean


clean_pr:
	rm -rf ./APR_new/innovus_stylus/APR/dbs/*
	rm -f ./APR_new/innovus_stylus/APR/innovus.log* ./APR_new/innovus_stylus/APR/innovus.logv* ./APR_new/innovus_stylus/APR/innovus.cmd* ./APR_new/innovus_stylus/APR/filenames.log

clean:
	rm -rf $(bld_dir); \
	rm -rf $(sim_dir)/prog*/result*.txt; \