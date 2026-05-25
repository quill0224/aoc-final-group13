puts "User script [info script]"

# set_db net:io_rte .skip_routing true

# set_db place_detail_legalization_inst_gap 2

delete_assigns
set_db init_no_new_assigns 1
set_db design_process_node 16
set_db design_top_routing_layer M9
set_db design_bottom_routing_layer M2

create_basic_path_groups -reset
create_basic_path_groups -expanded

# AOCV
set_db timing_analysis_type ocv
set_db timing_analysis_cppr both

set_timing_derate -max -early 0.8 -late 1.0
set_timing_derate -min -early 1.0 -late 1.1

# Tie
set_db add_tieoffs_max_fanout 10
set_db add_tieoffs_max_distance 100
set_db add_tieoffs_cells {TIEHBWP20P90 TIELBWP20P90}

# Filler
# set_db add_fillers_preserve_user_order true
# set_db add_fillers_cells { \
# DCAP32BWP20P90 DCAP16BWP20P90 DCAP8BWP20P90 DCAP4BWP20P90 \
# FILL64BWP20P90 FILL64BWP20P90LVT FILL64BWP20P90ULVT \
# FILL32BWP20P90 FILL32BWP20P90LVT FILL32BWP20P90ULVT \
# FILL16BWP20P90 FILL16BWP20P90LVT FILL16BWP20P90ULVT \
# FILL8BWP20P90 FILL8BWP20P90LVT FILL8BWP20P90ULVT \
# FILL4BWP20P90 FILL4BWP20P90LVT FILL4BWP20P90ULVT \ 
# FILL3BWP20P90 FILL3BWP20P90LVT FILL3BWP20P90ULVT \
# FILL2BWP20P90 FILL2BWP20P90LVT FILL2BWP20P90ULVT \
# FILL1BWP20P90 FILL1BWP20P90LVT FILL1BWP20P90ULVT }

# Antenna
# set_db route_design_antenna_diode_insertion true
# set_db route_design_antenna_cell_name {ANTENNABWP20P90}

# Power
source -quiet lab_script/set_activity.tcl
set_db power_write_db false
set_db power_write_static_currents false

set_db design_early_clock_flow        true

## setPlaceMode ##
set_db place_detail_use_no_diffusion_one_site_filler true
set_db place_detail_no_filler_without_implant true
set_db place_detail_check_cut_spacing true
set_db place_detail_check_route true
set_db design_cong_effort high
set_db place_detail_honor_inst_pad true
set_db place_detail_color_aware_legal true

