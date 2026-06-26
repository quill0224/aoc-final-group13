write_sdf outputs/CHIP_min.sdf -max_view AV_func_min_0p88v125c_rcb -typical_view AV_func_min_0p88v125c_rcb -min_view  AV_func_min_0p88v125c_rcb -map_removal -recompute_delaycal
write_sdf outputs/CHIP_max.sdf -max_view AV_func_max_0p72vm40c_rcw -typical_view AV_func_max_0p72vm40c_rcw -min_view  AV_func_max_0p72vm40c_rcw -map_removal -recompute_delaycal

#source my_script/write_netlist.tcl
