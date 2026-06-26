puts "User script [info script]"

read_mmmc file_preparation/design/mmmc.view.stylus

read_physical -lef {
/usr/cad/CBDK/Executable_Package/Collaterals/Tech/APR/N16ADFP_APR_Innovus/N16ADFP_APR_Innovus_11M.10a.tlef
/usr/cad/CBDK/Executable_Package/Collaterals/IP/stdcell/N16ADFP_StdCell/LEF/lef/N16ADFP_StdCell.lef
/usr/cad/CBDK/Executable_Package/Collaterals/IP/stdio/N16ADFP_StdIO/LEF/N16ADFP_StdIO.lef
/usr/cad/CBDK/Executable_Package/Collaterals/IP/bondpad/N16ADFP_BondPad/LEF/N16ADFP_BondPad.lef
file_preparation/design/N16ADFP_SRAM_100a.lef
file_preparation/design/TS1N16ADFPCLLLVTA512X45M4SWSHOD_custom.lef
file_preparation/design/N16ADFP_tag_array_100a.lef
file_preparation/design/N16ADFP_data_array_100a.lef
}

set_db init_power_nets {VDD VDDPST}
# set_db init_ground_nets {VSS VSSPST}
set_db init_ground_nets {VSS}
read_netlist -top CHIP file_preparation/design/CHIP_syn.v
set_db design_process_node 16
init_design
