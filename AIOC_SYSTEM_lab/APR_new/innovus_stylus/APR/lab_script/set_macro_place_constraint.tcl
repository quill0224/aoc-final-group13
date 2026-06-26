create_place_halo -halo_deltas {0.96 0.96 0.96 0.96} -all_blocks
create_route_halo -all_blocks -space 0.18 -bottom_layer M1 -top_layer M9

set_db place_global_align_macro true
set_macro_place_constraint -halo_sharing true

set_macro_place_constraint -min_space_to_core {6 6}
set_macro_place_constraint -min_space_to_macro {8 4}
set_macro_place_constraint -macro_corner_keepout {8 4}

