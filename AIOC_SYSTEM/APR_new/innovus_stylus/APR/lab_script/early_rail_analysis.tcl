set_rail_analysis_config -method era_static -power_switch_eco false -write_movies false -write_voltage_waveforms false -accuracy xd -power_grid_libraries techonly.cl -process_techgen_em_rules false -enable_rlrp_analysis false -voltage_source_search_distance 50 -ignore_shorts false -enable_mfg_effects false -report_via_current_direction false
write_power_pads -net VDD -auto_fetch
write_power_pads -net VDD -voltage_source_file CHIP_VDD.pp
write_power_pads -net VSS -auto_fetch
write_power_pads -net VSS -voltage_source_file CHIP_VSS.pp
set_pg_nets -net VDD -voltage 0.72 -threshold 0.68
set_pg_nets -net VSS -voltage 0 -threshold 0.04
set_rail_analysis_domain -domain_name PD -power_nets { VDD} -ground_nets { VSS}
set_power_data -reset
set_power_data -format current -scale 1 {static_VDD.ptiavg static_VSS.ptiavg}
set_power_pads -reset
set_power_pads -net VDD -format xy -file CHIP_VDD.pp
set_power_pads -net VSS -format xy -file CHIP_VSS.pp
set_package -reset
set_package -spice_model_file {} -mapping_file {}
set_net_group -reset
set_advanced_rail_options -reset
set_db power_grid_libraries techonly.cl
report_rail -type domain -results_directory ./ PD