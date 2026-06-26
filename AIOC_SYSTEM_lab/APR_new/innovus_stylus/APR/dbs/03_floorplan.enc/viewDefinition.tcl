if {![namespace exists ::IMEX]} { namespace eval ::IMEX {} }
set ::IMEX::dataVar [file dirname [file normalize [info script]]]
set ::IMEX::libVar ${::IMEX::dataVar}/libs

create_library_set -name lib_min_0p88v125c\
   -timing\
    [list ${::IMEX::libVar}/mmmc/N16ADFP_StdCellff0p88v125c.lib\
    ${::IMEX::libVar}/mmmc/N16ADFP_StdIOff0p88v1p98vm40c.lib\
    ${::IMEX::libVar}/mmmc/SRAM_ff0p88v0p88v125c_100a.lib\
    ${::IMEX::libVar}/mmmc/tag_array_ff0p88v0p88v125c_100a.lib\
    ${::IMEX::libVar}/mmmc/data_array_ff0p88v0p88v125c_100a.lib]
create_library_set -name lib_max_0p72vm40c\
   -timing\
    [list ${::IMEX::libVar}/mmmc/N16ADFP_StdCellss0p72vm40c.lib\
    ${::IMEX::libVar}/mmmc/N16ADFP_StdIOss0p72v1p62v125c.lib\
    ${::IMEX::libVar}/mmmc/SRAM_ss0p72v0p72vm40c_100a.lib\
    ${::IMEX::libVar}/mmmc/tag_array_ss0p72v0p72vm40c_100a.lib\
    ${::IMEX::libVar}/mmmc/data_array_ss0p72v0p72vm40c_100a.lib]
create_timing_condition -name TC_max_0p72vm40c\
   -library_sets [list lib_max_0p72vm40c]
create_timing_condition -name TC_min_0p88v125c\
   -library_sets [list lib_min_0p88v125c]
create_rc_corner -name RC_best\
   -pre_route_res 1\
   -post_route_res 1\
   -pre_route_cap 1\
   -post_route_cap 1\
   -post_route_cross_cap 1\
   -pre_route_clock_res 0\
   -pre_route_clock_cap 0\
   -temperature -40\
   -qrc_tech ${::IMEX::libVar}/mmmc/RC_best/qrcTechFile
create_rc_corner -name RC_worst\
   -pre_route_res 1\
   -post_route_res 1\
   -pre_route_cap 1\
   -post_route_cap 1\
   -post_route_cross_cap 1\
   -pre_route_clock_res 0\
   -pre_route_clock_cap 0\
   -temperature 125\
   -qrc_tech ${::IMEX::libVar}/mmmc/RC_worst/qrcTechFile
create_delay_corner -name DC_min_0p88v125c_rcb\
   -timing_condition {TC_min_0p88v125c}\
   -rc_corner RC_best
create_delay_corner -name DC_max_0p72vm40c_rcw\
   -timing_condition {TC_max_0p72vm40c}\
   -rc_corner RC_worst
create_constraint_mode -name CM_func\
   -sdc_files\
    [list ${::IMEX::libVar}/mmmc/CHIP_func.sdc]
create_analysis_view -name AV_func_max_0p72vm40c_rcw -constraint_mode CM_func -delay_corner DC_max_0p72vm40c_rcw
create_analysis_view -name AV_func_min_0p88v125c_rcb -constraint_mode CM_func -delay_corner DC_min_0p88v125c_rcb
set_analysis_view -setup [list AV_func_max_0p72vm40c_rcw] -hold [list AV_func_min_0p88v125c_rcb] -leakage AV_func_max_0p72vm40c_rcw -dynamic AV_func_max_0p72vm40c_rcw
