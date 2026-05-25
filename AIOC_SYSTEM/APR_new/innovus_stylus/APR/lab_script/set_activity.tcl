set_db power_method static
set_db power_corner max
set_db power_write_db true
set_db power_write_static_currents true
set_db power_honor_negative_energy true
set_db power_ignore_control_signals true

set_default_switching_activity -reset
set_default_switching_activity -input_activity 0.2 -period 8.0
set_default_switching_activity -sequential_activity 0.2
read_activity_file -reset
# read_activity_file -format TCF -scope CHIP ../../sim/pre_sim/CHIP.tcf
# read_activity_map_file -rtl_to_gate ../../genus/name_map.rpt

#set_power -reset
#set_dynamic_power_simulation -reset
#set_db power_grid_libraries techonly.cl

