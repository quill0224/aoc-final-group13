delete_empty_hinsts

update_names -verilog
update_names -hport -map {{/ _}}
update_names -net -map {{/ _}}


write_netlist outputs/CHIP_pr.v
# set DCAP_CELL_LIST [get_db [get_db base_cells DCAP*] .name]
# set PVDD_CELL_LIST [get_db [get_db base_cells PVDD*] .name]
# set PVDD_CELL_LIST [get_db [get_db base_cells PD*] .name]
# set FILLER_CELL_LIST [get_db [get_db base_cells FILL*] .name]
# set PFILLER_CELL_LIST [get_db [get_db base_cells PFILL*] .name]
# set BOUNDARY_CELL_LIST [get_db [get_db base_cells BOUNDARY*] .name]
# set TAP_CELL_LIST [get_db [get_db base_cells TAP*] .name]
# set PCORNER_LIST [get_db [get_db base_cells PCORNER*] .name]
# set PCORNER_LIST [get_db [get_db base_cells PAD80APB_LF_BU*] .name]

# write_netlist -include_pg_ports  -include_phys_cells "$DCAP_CELL_LIST $PVDD_CELL_LIST" -exclude_insts_of_cells "$PFILLER_CELL_LIST $PCORNER_LIST" -exclude_leaf_cells outputs/CHIP_pg.v

#write_netlist -include_pg_ports  -include_phys_cells "$DCAP_CELL_LIST $PVDD_CELL_LIST $FILLER_CELL_LIST $PFILLER_CELL_LIST $BOUNDARY_CELL_LIST $TAP_CELL_LIST" outputs/CHIP_pg_full.v  -exclude_leaf_cells 

set DECAP_CELL_LIST [get_db [get_db base_cells DCAP*] .name]
set PVDD_CELL_LIST [get_db [get_db base_cells PVDD*] .name]
set FILLER_CELL_LIST [get_db [get_db base_cells FILL*] .name]
set PFILLER_CELL_LIST [get_db [get_db base_cells PFILL*] .name]
set PCORNER_CELL_LIST [get_db [get_db base_cells PCORNER*] .name]
write_netlist -include_pg_ports  -include_phys_cells "$DECAP_CELL_LIST $PVDD_CELL_LIST" -exclude_insts_of_cells "$FILLER_CELL_LIST $PFILLER_CELL_LIST $PCORNER_CELL_LIST" -exclude_leaf_cells outputs/CHIP_pg.v

