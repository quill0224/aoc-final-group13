# Create Bump
# 2025.10.12 Sun. Rowan Lin

puts "User script [info script]"

create_bump -cell PAD80APB_LF_BU -name_format Bump_%c_%r -pitch {154 154} -location {80 80} -pattern_array {12 12}
unassign_bumps -all

assign_pg_bumps -nets VDD -bumps {Bump_5_6}
assign_pg_bumps -nets VDDPST -bumps {Bump_5_7}
assign_pg_bumps -nets VDD -bumps {Bump_6_6}
assign_pg_bumps -nets VDDPST -bumps {Bump_7_7}
assign_pg_bumps -nets VSS -bumps {Bump_6_7 }
assign_pg_bumps -nets VSS -bumps {Bump_7_6 }
assign_pg_bumps -nets VDD -bumps {Bump_7_8}

# create_bump_connect_target_constraint -bumps {Bump_6_7} -io_inst CORE_PG1 -pin_name VSS
# create_bump_connect_target_constraint -bumps {Bump_6_7} -io_inst CORE_PG2 -pin_name VSS
# create_bump_connect_target_constraint -bumps {Bump_6_7} -io_inst CORE_PG3 -pin_name VSS
# create_bump_connect_target_constraint -bumps {Bump_6_7} -io_inst CORE_PG4 -pin_name VSS

assign_bumps
set_db flip_chip_connect_power_cell_to_bump true
set_db flip_chip_multiple_connection default
set_db flip_chip_route_width 12
set_db flip_chip_prevent_via_under_bump false
set_db flip_chip_bottom_layer AP
set_db flip_chip_top_layer AP
set_db flip_chip_route_style diagonal
route_flip_chip -target connect_bump_to_pad -route_engine global_detail -bottom_layer AP -top_layer AP -route_width 12