# Top File
# 2025.06.19 Thu. Rowan Lin

#===============================================================================================================================================================================#

# Step 1: initialize design

source -quiet lab_script/design_import.tcl
source -quiet lab_script/config.tcl
source -quiet lab_script/create_pg_pad.tcl
source -quiet lab_script/connect_global_net.tcl
source -quiet lab_script/config_cts.tcl

write_db dbs/01_init.enc

#===============================================================================================================================================================================#

# Step 2: floorplan

source -quiet lab_script/floorplan.tcl

#===============================================================================================================================================================================#

# Step 3: powerplan

source -quiet lab_script/powerplan.tcl

#===============================================================================================================================================================================#

# Step 4: Add EndCap

source -quiet lab_script/add_endcaps_20p90.tcl

#===============================================================================================================================================================================#

# Step 5: Add WellTap

source -quiet lab_script/add_well_taps_20p90.tcl

#===============================================================================================================================================================================#

# Step 6: Placement

source -quiet lab_script/config.tcl

place_design
place_opt_design

# Timing check(pre-cts, setup time)

# ECO (optimize design)

# Timing check again(pre-cts, setup time)

write_db dbs/12_placement.enc

#===============================================================================================================================================================================#

# Step 7: CTS

# source -quiet lab_script/config_cts.tcl
reset_clock_latency [all_clocks]
ccopt_design

# Timing check again(post-cts, setup time)

# ECO (optimize design)

# Timing check again(post-cts, setup time)

# Timing chmeck(post-cts, hold time)

# ECO (optimize design)

# Timing check again(post-cts, hold time)

write_db dbs/13_cts.enc

# Add tie
if {[get_db add_tieoffs_cells] ne "" } {
    delete_tieoffs
    add_tieoffs -matching_power_domains true
}

# write_db dbs/postcts.enc
write_db dbs/13_cts.enc

#===============================================================================================================================================================================#

# Step 8: Route

set_db route_design_antenna_diode_insertion 1
set_db route_design_with_timing_driven 1
set_db route_design_with_eco 1
set_db route_design_with_si_driven 1
set_db route_design_top_routing_layer 9
set_db route_design_bottom_routing_layer 2
set_db route_design_detail_end_iteration 5
set_db route_design_with_timing_driven true
set_db route_design_with_si_driven true
route_design -global_detail -via_opt -wire_opt

source -quiet lab_script/set_inst_padding.tcl
place_detail
route_eco
check_drc

source lab_script/fix_metal_same_mask.tcl
route_eco
check_drc

write_db dbs/14_route.enc

set_db delaycal_enable_si true

# Timing check(post-route, setup time)

# ECO (optimize design)

# Timing check again(post-route, setup time)

# Timing check(post-route, hold time)

# ECO (optimize design)

write_db dbs/14_route.enc

# Check DRC
set_db check_drc_limit 100000
check_drc
fix_via -min_step
fix_via -short
fix_via -min_cut
# check again, the drc will be zero
check_drc

delete_obj [get_db route_blockages BumpBlk]
delete_obj [get_db route_blockages {RBKM234}]
delete_obj [get_db route_blockages RBKPADPIN]
delete_obj [get_db place_blockages -if {.type==soft}]

write_db dbs/14_route.enc

#===============================================================================================================================================================================#

# Step 9: add filler

# delete_filler -inst FILLER*

source lab_script/add_fillers_20p90.tcl

write_db dbs/15_add_filler.enc

#===============================================================================================================================================================================#

# Step 10: delete inst

# Delete unplaced cells
get_db insts -if {.place_status == unplaced}
delete_obj [get_db insts -if {.place_status == unplaced}]

write_db dbs/16_before_bound.enc

#===============================================================================================================================================================================#

# Step 11: create bonding pad

# create bumps

source -quiet lab_script/create_bump.tcl

# create chip boundary

source -quiet lab_script/create_chip_boundary.tcl

# Check DRC
set_db check_drc_limit 100000
check_drc
fix_via -min_step
fix_via -short
fix_via -min_cut
# check again, the drc will be zero
check_drc

write_db dbs/17_create_bonding_pad.enc

#===============================================================================================================================================================================#

# Step 12: finish design

delete_empty_hinsts

delete_route_halos -all_blocks
delete_place_halo -all_blocks

write_db dbs/18_finish.enc 

source -quiet lab_script/write_stream.tcl
source -quiet lab_script/write_netlist.tcl
source -quiet lab_script/write_sdf.tcl

