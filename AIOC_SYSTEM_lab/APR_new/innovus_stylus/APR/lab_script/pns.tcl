
proc createPowerStripeRail { direction layer nets offset width spacing pitch RTopLayer RBotLayer BTopLayer BBotLayer} {
    variable curRegionBKG

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
    set_db add_stripes_stacked_via_top_layer AP
    set_db add_stripes_stacked_via_bottom_layer M1
    set_db add_stripes_via_using_exact_crossover_size false
    set_db add_stripes_split_vias false
    set_db add_stripes_orthogonal_only true
    set_db add_stripes_allow_jog { block_ring }
    set_db add_stripes_skip_via_on_pin {  Block standardcell }
    set_db add_stripes_skip_via_on_wire_shape {  noshape Stripe  }
    add_stripes -nets $nets -layer $layer -direction $direction -width $width -spacing $spacing -set_to_set_distance $pitch  -start_from bottom -start_offset $offset -switch_layer_over_obs false -pad_core_ring_top_layer_limit $RTopLayer -pad_core_ring_bottom_layer_limit $RBotLayer -block_ring_top_layer_limit $BTopLayer -block_ring_bottom_layer_limit $BBotLayer -use_wire_group 0 -snap_wire_center_to_grid none -user_class "manual_rail"
}

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

proc createRegionStripe { direction layer nets offset width spacing pitch region} {

    if { $region == "Core" } {
        set area [get_db designs .core_bbox]
    } elseif {$region == "Die" } {
        set area [get_db designs .bbox]
    } else {
        puts "unknow region"
        return;
    }

    set LayerNum [get_db layer:$layer .route_index] 
    set botLayerNum [expr $LayerNum - 1]
    if {$botLayerNum < 1 } {
        set botLayerNum 1
    }
    set topLayerNum [expr $LayerNum + 1]
    if {$topLayerNum > 11} {
        set topLayerNum 11
    } 
    set botLayer    [get_db layer:$botLayerNum .name]
    set topLayer    [get_db layer:$topLayerNum .name]

    set direction [expr {$direction eq "H" ? "horizontal" : "vertical" }]
   
    set_db add_stripes_ignore_block_check false
    set_db add_stripes_break_at none
    set_db add_stripes_route_over_rows_only false
    set_db add_stripes_rows_without_stripes_only false
    set_db add_stripes_extend_to_closest_target none
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
    add_stripes -nets $nets -layer $layer -direction $direction -width $width -spacing $spacing -set_to_set_distance $pitch -start_from bottom -start_offset $offset -switch_layer_over_obs false -max_same_layer_jog_length 2 -pad_core_ring_top_layer_limit $topLayer -pad_core_ring_bottom_layer_limit $botLayer -block_ring_top_layer_limit $topLayer -block_ring_bottom_layer_limit $botLayer -use_wire_group 0 -snap_wire_center_to_grid none -area $area
}


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
    set_db add_rings_skip_via_on_pin {  standardcell }
    set_db add_rings_skip_via_on_wire_shape {  noshape }
    add_rings -nets $nets -type core_rings -follow core -layer [list top $hlayer bottom $hlayer left $vlayer right $vlayer] -width [list top $width bottom $width left $width right $width] -spacing [list top $spacing bottom $spacing left $spacing right $spacing] -offset [list top $offset bottom $offset left $offset right $offset] -center 0 -threshold 0 -jog_distance 0 -snap_wire_center_to_grid none -use_wire_group 1 -use_wire_group_bits $wire_group -use_interleaving_wire_group 1
    
}

proc initializePG {} {
    editDelete -physical_pin -use POWER
    editDelete -use POWER
}

proc initializeRegionBKG {} {
    variable curRegionBKG
    array unset curRegionBKG

    set Die  [dbget top.fplan.box -e]
    set Core [dbget top.fplan.coreBox -e]
    set STD  [dbget top.fplan.rows.box -e]

    set curRegionBKG(Core) [dbshape $Die ANDNOT $Core -output rect]
    set curRegionBKG(STD)  [dbshape $Die ANDNOT [dbShape $STD SIZEY 0.1] -output rect]
}

proc runPGPlan {} {
    
    #add routing blockage for bump
    if {[file exists lab_script/create_bump_stylus.tcl]} {
        source -quiet lab_script/create_bump_stylus.tcl
        create_bump_and_route
        create_bump_blockage
        delete_bump_and_route
    }
    
    #=== core power ring
    #createPowerRing  nets      TBlayer LRlayer width spacing offset wire_group  
    #createPowerRing   {VDD VSS}   M10    M11     2.1     1       1.7    13
    #createPowerRing   {VDD VSS}   M8    M9      2.1     1       1.7    13
    #createPowerRing   {VDD VSS}   M8    M9      2     1.1       0.8    13
    createPowerRing   {VDD VSS}   M6     M7     2     1.1       0.8    13
    createPowerRing   {VDD VSS}   M6     M5     2     1.1      0.8    13
    
    #=== sroute pad pin
    set_db route_special_via_connect_to_shape { ring }
    route_special -connect pad_pin -layer_change_range { M1(1) AP(10) } -block_pin_target nearest_target -pad_pin_port_connect {all_port all_geom} -pad_pin_target nearest_target -pad_pin_layer_range { M1(1) M4(4) } -allow_jogging 0 -crossover_via_layer_range { M1(1) AP(10) } -nets { VDD VSS } -allow_layer_change 1 -target_via_layer_range { M1(1) AP(10) }


    source -quiet lab_script/create_padpin_blockage.tcl

    createPowerRing   {VDD VSS}   M4     M3     2     1.1      0.8    13

    #=== block ring , to terminate followpin
    add_rings -nets {VDD VSS} -type block_rings -around each_block -layer {top M2 bottom M2 left M3 right M3} -width {top 0.1 bottom 0.1 left 0.1 right 0.1} -spacing {top 0.1 bottom 0.1 left 0.1 right 0.1} -offset {top 0.5 bottom 0.5 left 0.5 right 0.5} -center 0 -threshold 0 -jog_distance 0 -snap_wire_center_to_grid none -skip_side {top bottom}
    
    foreach cell [get_db [get_db insts -if {.base_cell.base_class == block}] .name] {
        set llx [get_db inst:$cell .bbox.ll.x]
        set lly [get_db inst:$cell .bbox.ll.y]
        set urx [get_db inst:$cell .bbox.ur.x]
        set ury [get_db inst:$cell .bbox.ur.y]
        create_route_blockage -name RBKM234 -pg_nets -layers {M2} -rects [list [expr $llx-0.45] $lly $llx $ury]
        create_route_blockage -name RBKM234 -pg_nets -layers {M2} -rects [list $urx $lly [expr $urx + 0.45] $ury]
    }
    
    #=== power strape
    #createPowerStripe dir layer nets           offset width spacing pitch  snap
    createPowerStripe  "V" "M9" [list VDD VSS]    1.8   1.8   5.4    14.4 "none"
    createPowerStripe  "H" "M8"  [list VSS]      1.44   0.864  0    2.88 "half_grid"
    createPowerStripe  "H" "M8"  [list VDD]      0      0.864  0    2.88 "half_grid"
    createPowerStripe  "V" "M7"  [list VSS]     3.6    0.24  0       7.2    "grid"
    createPowerStripe  "V" "M7"  [list VDD]     7.2      0.24  0     7.2    "grid"
    createPowerStripe  "H" "M6"  [list VSS]     3.6    0.24  0       7.2    "grid"
    createPowerStripe  "H" "M6"  [list VDD]     0      0.24  0       7.2    "grid"
    createPowerStripe  "V" "M5"  [list VSS]     3.6    0.24  0       7.2    "grid"
    createPowerStripe  "V" "M5"  [list VDD]     7.2      0.24  0       7.2    "grid"

    #createPowerStripe  "H" "M4"  [list VSS]     3.6    0.24  0       7.2    "grid"
    #createPowerStripe  "H" "M4"  [list VDD]     0      0.24  0       7.2    "grid"
    #createPowerStripe  "V" "M3"  [list VSS]     1.47   0.1   0       2.94   "half_grid"
    #createPowerStripe  "V" "M3"  [list VDD]     2.94   0.1   0       2.94   "half_grid"

    #check_power_vias
    
   #== expand via3 ~ via6
   #set corebox [get_db designs .core_bbox]
   #select_obj [get_obj_in_area -are $corebox -obj_type special_via -layers {VIA3 VIA4 VIA5 VIA6}]
   #update_power_vias -skip_via_on_pin standardcell -bottom_layer M3 -selected_vias 1 -via_scale_height 180 -update_vias 1 -via_scale_width 180 -top_layer M7

 
    write_db dbs/pns_stripe.enc
    #=== followpin
    set_db [get_db insts -if {.base_cell.class == core}] .place_status unplaced
 
    set_db route_special_via_connect_to_shape { ring stripe }

    
    


    # current script --> innovus drc clean, calibre drc violation
    route_special -connect core_pin -layer_change_range { M1(1) M5(5) } -block_pin_target nearest_target -core_pin_target first_after_row_end -allow_jogging 0 \
    -crossover_via_layer_range { M1(1) M5(5) } -nets { VDD VSS } -allow_layer_change 1 -target_via_layer_range { M1(1) M5(5) } 
    #== For 7.5 cell, full hight via2 may cause drc
    select_routes -shapes followpin -via_cell {VIAGEN12* VIAGEN23* VIAGEN34*}
    update_power_via -bottom_layer M1 -top_layer M4 -update_vias 1 -selected_vias 1  -via_scale_height 70 -via_scale_width 130
    
    # try-out script --> innovus drc clean, calibre drc clean
    # route_special -connect core_pin -layer_change_range { M2(2) M5(5) } -block_pin_target nearest_target -core_pin_target first_after_row_end -allow_jogging 0 \
    # -crossover_via_layer_range { M2(2) M5(5) } -nets { VDD VSS } -allow_layer_change 1 -target_via_layer_range { M2(2) M5(5) }
    #== For 7.5 cell, full hight via2 may cause drc
    # select_routes -shapes followpin -via_cell {VIAGEN23* VIAGEN34*}
    # update_power_via -bottom_layer M2 -top_layer M4 -update_vias 1 -selected_vias 1  -via_scale_height 70 -via_scale_width 130
    
    
    
    # To make standard cells easier at routing stage, need to delete power via1 first, then add the via1 back at post-route stage 
    # select_routes -shapes followpin -via_cell {VIAGEN12*}
    # update_power_via -bottom_layer M1 -top_layer M2 -selected_vias 1 -delete_vias 1



    write_db dbs/followpin.enc

    #=== M2 rail
    #createPowerStripeRail direction layer nets  offset width spacing pitch RTopLayer RBotLayer BTopLayer BBotLayer
    createPowerStripeRail  "H" "M2" [list VDD]   -0.032  0.064  0   1.152  3    1    2    1
    createPowerStripeRail  "H" "M2" [list VSS]  0.544  0.064   0   1.152  3    1    2    1
    
    write_db dbs/followpin.enc


    delete_obj [get_db route_blockages {RBKM234}]
    delete_obj [get_db route_blockages RBKPADPIN]
    create_pg_model_for_macro_place -file golden_mimic_power_mesh.tcl
    
    set_db check_drc_limit 100000
    check_drc
    write_db dbs/followpin.enc
    
    fix_via -min_step
    write_db dbs/pns.enc
}

runPGPlan
