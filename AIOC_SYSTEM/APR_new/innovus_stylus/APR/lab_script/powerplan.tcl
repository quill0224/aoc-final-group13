# Powerplan
# 2025.06.19 Thu. Rowan Lin

#===============================================================================================================================================================================#

# Step 1: create bump blockage

# add routing blockage for bump
#  loads create_bump_stylus.tcl, which typically defines the following three procedures
# source -quiet lab_script/create_bump_stylus.tcl
# Creates bump cells and temporary routing for visualization or alignment purposes.
# create_bump_and_route
# Generates routing blockages above bump regions to prevent metal traces from passing through those areas.
# create_bump_blockage
# Removes the temporary bump cells and routing, leaving only the blockages.
# delete_bump_and_route

# write_db dbs/04_create_bump_blockage.enc

#===============================================================================================================================================================================#

# Step 2: create core rings

# Function declaration
proc createPowerRing { nets hlayer vlayer width spacing offset wire_group } {
    set vLayerNum [get_db layer:$vlayer .route_index] 
    set hLayerNum [get_db layer:$hlayer .route_index] 
    if { $vLayerNum > $hLayerNum } {
        set botLayerNum $hLayerNum
        set topLayerNum $vLayerNum
    } else {
        set botLayerNum $vLayerNum
        set topLayerNum $hLayerNum
    }

    if {$botLayerNum >= 1} {
        set botLayerNum [expr $botLayerNum - 1]
    }
    if {$topLayerNum < 11} {
        set topLayerNum [expr $topLayerNum + 1]
    }
    set botLayer    [get_db layer:$botLayerNum .name]
    
    set_db add_rings_target default
    set_db add_rings_extend_over_row 0
    set_db add_rings_ignore_rows 0
    set_db add_rings_avoid_short 0
    set_db add_rings_skip_shared_inner_ring none
    set_db add_rings_stacked_via_top_layer $topLayerNum
    set_db add_rings_stacked_via_bottom_layer $botLayerNum
    set_db add_rings_via_using_exact_crossover_size 1
    set_db add_rings_orthogonal_only true
    set_db add_rings_skip_via_on_pin { standardcell }
    set_db add_rings_skip_via_on_wire_shape { noshape }
    add_rings -nets $nets -type core_rings -follow core -layer [list top $hlayer bottom $hlayer left $vlayer right $vlayer] -width [list top $width bottom $width left $width right $width] -spacing [list top $spacing bottom $spacing left $spacing right $spacing] -offset [list top $offset bottom $offset left $offset right $offset] -center 0 -threshold 0 -jog_distance 0 -snap_wire_center_to_grid none -use_wire_group 1 -use_wire_group_bits $wire_group -use_interleaving_wire_group 1
}

createPowerRing   {VDD VSS}        M6       M5        2       1.1       0.8        12

write_db dbs/05_create_core_ring.enc

#===============================================================================================================================================================================#

# Step 3: connect pad pins

# Since pad pin locations and layers may not perfectly align with the power ring, the tool will automatically select a connection path starting from the ring, traversing intermediate layers to reach the pad pin.
# Setting {M1(1) AP(10)} allows the tool to freely choose a legal and DRC-clean routing path across multiple layers to ensure proper connectivity to the ring.
set_db route_special_via_connect_to_shape { ring }
route_special -connect pad_pin -layer_change_range { M1(1) M6(6) } -block_pin_target nearest_target -pad_pin_port_connect {all_port one_geom} -pad_pin_target {nearest_target} -pad_pin_layer_range { M1(1) M4(4) } -allow_jogging 0 -crossover_via_layer_range { M1(1) M6(6) } -nets { VDD VSS } -allow_layer_change 1 -target_via_layer_range { M1(1) M6(6) }

# Create pad pin blockage
source -quiet lab_script/create_padpin_blockage.tcl

write_db dbs/06_connect_pad_pin.enc

#===============================================================================================================================================================================#

# Step 4 : create block rings

# add_rings -nets {VDD VSS} -type block_rings -around each_block -layer {top M2 bottom M2 left M3 right M3} -width {top 0.1 bottom 0.1 left 0.1 right 0.1} -spacing {top 0.1 bottom 0.1 left 0.1 right 0.1} -offset {top 0.5 bottom 0.5 left 0.5 right 0.5} -center 0 -threshold 0 -jog_distance 0 -snap_wire_center_to_grid none

# write_db dbs/07_create_block_ring.enc

#===============================================================================================================================================================================#

# Step 5: create power stripes

# Function declaration
proc createPowerStripe { direction layer nets offset width spacing pitch snap} {

    set LayerNum [get_db layer:$layer .route_index] 
    if {$LayerNum > 1} {
        set botLayerNum [expr $LayerNum - 1]
    }
    if {$LayerNum < 11} {
        set topLayerNum [expr $LayerNum + 1]
    }
    set botLayer    [get_db layer:$botLayerNum .name]
    set topLayer    [get_db layer:$topLayerNum .name]

    set direction [expr {$direction eq "H" ? "horizontal" : "vertical" }]
   
    set_db add_stripes_ignore_block_check false
    set_db add_stripes_break_at none
    set_db add_stripes_route_over_rows_only false
    set_db add_stripes_rows_without_stripes_only false
    set_db add_stripes_extend_to_closest_target ring
    set_db add_stripes_stop_at_last_wire_for_area false
    set_db add_stripes_partial_set_through_domain false
    set_db add_stripes_ignore_non_default_domains false
    set_db add_stripes_trim_antenna_back_to_shape none
    set_db add_stripes_spacing_type edge_to_edge
    set_db add_stripes_spacing_from_block 0
    set_db add_stripes_stripe_min_length stripe_width
    set_db add_stripes_stacked_via_top_layer $topLayer
    set_db add_stripes_stacked_via_bottom_layer $botLayer
    set_db add_stripes_via_using_exact_crossover_size false
    set_db add_stripes_split_vias false
    set_db add_stripes_orthogonal_only true
    set_db add_stripes_allow_jog { block_ring }
    set_db add_stripes_skip_via_on_pin {  standardcell }
    set_db add_stripes_skip_via_on_wire_shape {  noshape   }

    add_stripes -nets $nets -layer $layer -direction $direction -width $width -spacing $spacing -set_to_set_distance $pitch -start_from bottom -start_offset $offset -switch_layer_over_obs false -max_same_layer_jog_length 2 -pad_core_ring_top_layer_limit $topLayer -pad_core_ring_bottom_layer_limit $botLayer -block_ring_top_layer_limit $topLayer -block_ring_bottom_layer_limit $botLayer -use_wire_group 0 -snap_wire_center_to_grid $snap 

}

# Place routing blockage around macros
foreach cell [get_db [get_db insts -if {.base_cell.base_class == block}] .name] {
    set llx [get_db inst:$cell .bbox.ll.x]
    set lly [get_db inst:$cell .bbox.ll.y]
    set urx [get_db inst:$cell .bbox.ur.x]
    set ury [get_db inst:$cell .bbox.ur.y]
    create_route_blockage -name RBKM234 -pg_nets -layers {M2 M3 M4} -rects [list [expr $llx-0.45] $lly $llx $ury]
    create_route_blockage -name RBKM234 -pg_nets -layers {M2 M3 M4} -rects [list $urx $lly [expr $urx + 0.45] $ury]
}

#createPowerStripe dir layer nets            offset  width  spacing  pitch  snap
createPowerStripe  "V" "M9"  [list VDD VSS]    1.8    1.8    1.8     7.2    "none"
createPowerStripe  "H" "M8"  [list VSS]        1.44   0.864   0      2.88   "half_grid"
createPowerStripe  "H" "M8"  [list VDD]        0      0.864   0      2.88   "half_grid"
createPowerStripe  "V" "M7"  [list VSS]        3.6    0.24    0      7.2    "grid"
createPowerStripe  "V" "M7"  [list VDD]        7.2    0.24    0      7.2    "grid"
createPowerStripe  "H" "M6"  [list VSS]        3.6    0.24    0      7.2    "grid"
createPowerStripe  "H" "M6"  [list VDD]        0      0.24    0      7.2    "grid"
createPowerStripe  "V" "M5"  [list VSS]        3.6    0.24    0      7.2    "grid"
createPowerStripe  "V" "M5"  [list VDD]        7.2    0.24    0      7.2    "grid"

# delete_obj [get_db route_blockages {RBKM234}]

# add AP layer to satisfy density rule
# set_db add_stripes_ignore_block_check false
# set_db add_stripes_break_at none
# set_db add_stripes_route_over_rows_only false
# set_db add_stripes_rows_without_stripes_only false
# set_db add_stripes_extend_to_closest_target ring
# set_db add_stripes_stop_at_last_wire_for_area false
# set_db add_stripes_partial_set_through_domain false
# set_db add_stripes_ignore_non_default_domains false
# set_db add_stripes_trim_antenna_back_to_shape none
# set_db add_stripes_spacing_type edge_to_edge
# set_db add_stripes_spacing_from_block 0
# set_db add_stripes_stripe_min_length stripe_width
# set_db add_stripes_stacked_via_top_layer AP
# set_db add_stripes_stacked_via_bottom_layer M9
# set_db add_stripes_via_using_exact_crossover_size false
# set_db add_stripes_split_vias false
# set_db add_stripes_orthogonal_only true
# set_db add_stripes_allow_jog { block_ring }
# set_db add_stripes_skip_via_on_pin {  standardcell }
# set_db add_stripes_skip_via_on_wire_shape {  noshape   }
# add_stripes -nets {VDD VSS} -layer AP -direction horizontal -width 3.6 -spacing 1.8 -set_to_set_distance 10 -start_from bottom -switch_layer_over_obs false -max_same_layer_jog_length 2 -pad_core_ring_top_layer_limit AP -pad_core_ring_bottom_layer_limit M1 -block_ring_top_layer_limit AP -block_ring_bottom_layer_limit M1 -use_wire_group 0 -snap_wire_center_to_grid none

write_db dbs/07_create_power_stripe.enc

#===============================================================================================================================================================================#

# Step 6: connect follow pin

# Enabling route_special -connect core_pin allows stripes to connect to standard cell power pins.
# This is necessary if you want to re-execute this step because the tool only auto-detects connection points when cells are unplaced.
# set_db [get_db insts -if {.base_cell.class == core}] .place_status unplaced

# It permits the tool to trace upward from cell pins to find and connect to the power ring or stripes
set_db route_special_via_connect_to_shape { ring stripe }

# This is the actual step that connects the cell's VDD/VSS pins to the power distribution network.
route_special -connect core_pin -layer_change_range { M1(1) M5(5) } -block_pin_target nearest_target -core_pin_target first_after_row_end -allow_jogging 0 -crossover_via_layer_range { M1(1) M5(5) } -nets { VDD VSS } -allow_layer_change 1 -target_via_layer_range { M1(1) M5(5) } 

# delete halo
delete_obj [get_db route_blockages {RBKM234}]
delete_obj [get_db route_blockages RBKPADPIN]

# Add power mesh.tcl
add_power_mesh_colors
create_pg_model_for_macro_place -file golden_mimic_power_mesh.tcl

write_db dbs/08_connect_follow_pin.enc

#===============================================================================================================================================================================#

# Step 7: check DRC

set_db check_drc_limit 100000
check_drc
fix_via -min_step
# check again, the drc will be zero
check_drc

write_db dbs/09_powerplan.enc
