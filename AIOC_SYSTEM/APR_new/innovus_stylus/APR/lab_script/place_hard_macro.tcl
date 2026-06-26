puts "User script [info script]"

set h_offset 6
set h_space 16

set v_offset 6
set v_space 8

delete_relative_floorplan -all

# ### top left side ###
# create_relative_floorplan -ref_type core_boundary -ref core_bond -horizontal_edge_separate "1 -$v_offset 1" -vertical_edge_separate "0 $h_offset 0" -place u_TOP/IM1/i_SRAM

# ### top right side ###
# create_relative_floorplan -ref_type core_boundary -ref core_bond -horizontal_edge_separate "1 -$v_offset 1" -vertical_edge_separate "2 -$h_offset 2" -place u_TOP/DM1/i_SRAM

# ### left-hand side ###
# create_relative_floorplan -ref_type object -ref u_TOP/IM1/i_SRAM -horizontal_edge_separate "3 -$v_space 1" -vertical_edge_separate "0 0 0" -place u_TOP/CPU_wrapper/cache_inst/TA/i_tag_array2

# ### right-hand side ###
# create_relative_floorplan -ref_type object -ref u_TOP/DM1/i_SRAM -horizontal_edge_separate "3 -$v_space 1" -vertical_edge_separate "2 0 2" -place u_TOP/CPU_wrapper/cache_data/TA/i_tag_array2

### oriantation ###
set_db inst:u_TOP/DM1/i_SRAM .orient MY
