puts "User script [info script]"

set_db add_endcaps_left_edge  {BOUNDARY_RIGHTBWP20P90}
set_db add_endcaps_right_edge {BOUNDARY_LEFTBWP20P90}

set_db add_endcaps_left_top_corner {BOUNDARY_PCORNERBWP20P90} 
set_db add_endcaps_left_bottom_corner {BOUNDARY_NCORNERBWP20P90} 

set_db add_endcaps_top_edge  {BOUNDARY_PROW4BWP20P90 BOUNDARY_PROW3BWP20P90 BOUNDARY_PROW2BWP20P90 BOUNDARY_PROW1BWP20P90}
set_db add_endcaps_bottom_edge {BOUNDARY_NROW4BWP20P90 BOUNDARY_NROW3BWP20P90 BOUNDARY_NROW2BWP20P90 BOUNDARY_NROW1BWP20P90}

set_db add_endcaps_left_top_edge  {FILL3BWP20P90}
set_db add_endcaps_right_top_edge {FILL3BWP20P90}

set_db add_endcaps_left_bottom_edge  {FILL3BWP20P90}
set_db add_endcaps_right_bottom_edge {FILL3BWP20P90}

set_db add_endcaps_boundary_tap true

set_db add_well_taps_rule 50.76
set_db add_well_taps_top_tap_cell BOUNDARY_PTAPBWP20P90
set_db add_well_taps_bottom_tap_cell BOUNDARY_NTAPBWP20P90

add_endcaps

# check DRC
set_db check_drc_limit 100000
check_drc
# If there is any error, fix it
fix_via -min_step
# check again, the drc will be zero
check_drc

write_db dbs/10_add_endcap.enc
