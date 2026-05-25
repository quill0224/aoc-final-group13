puts "User script [info script]"

read_mmmc file_preparation/design/mmmc.view.stylus

read_physical -lef {
/usr/cad/CBDK/Executable_Package/Collaterals/Tech/APR/N16ADFP_APR_Innovus/N16ADFP_APR_Innovus_11M.10a.tlef
/usr/cad/CBDK/Executable_Package/2025_AVSD_APR_file/lef/N16ADFP_StdCell.lef
/usr/cad/CBDK/Executable_Package/2025_AVSD_APR_file/lef/N16ADFP_StdIO.lef
/usr/cad/CBDK/Executable_Package/2025_AVSD_APR_file/lef/N16ADFP_BondPad.lef
/usr/cad/CBDK/Executable_Package/2025_AVSD_APR_file/lef/N16ADFP_SRAM_100a.lef
/usr/cad/CBDK/Executable_Package/2025_AVSD_APR_file/lef/N16ADFP_tag_array_100a.lef
/usr/cad/CBDK/Executable_Package/2025_AVSD_APR_file/lef/N16ADFP_data_array_100a.lef
}

set_db init_power_nets {VDD VDDPST}
# set_db init_ground_nets {VSS VSSPST}
set_db init_ground_nets {VSS}
read_netlist -top CHIP file_preparation/design/CHIP_syn.v
init_design
