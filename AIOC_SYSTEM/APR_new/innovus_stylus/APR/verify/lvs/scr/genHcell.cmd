#! /usr/bin/tclsh
set HCELL_file "HCELL"
set LVSBOX_file "LVSBOX"

set lefList  " \
  /usr/cad/CBDK/Executable_Package/Collaterals/Tech/APR/N16ADFP_APR_Innovus/N16ADFP_APR_Innovus_11M.10a.tlef \
  /usr/cad/CBDK/Executable_Package/2025_AVSD_APR_file/lef/N16ADFP_StdCell.lef \
  /usr/cad/CBDK/Executable_Package/2025_AVSD_APR_file/lef/N16ADFP_StdIO.lef \
  /usr/cad/CBDK/Executable_Package/2025_AVSD_APR_file/lef/N16ADFP_BondPad.lef \
  /usr/cad/CBDK/Executable_Package/2025_AVSD_APR_file/lef/N16ADFP_SRAM_100a.lef \
  /usr/cad/CBDK/Executable_Package/2025_AVSD_APR_file/lef/N16ADFP_tag_array_100a.lef \
  /usr/cad/CBDK/Executable_Package/2025_AVSD_APR_file/lef/N16ADFP_data_array_100a.lef \
"

set hcell_hd [open $HCELL_file "w"]
set lvsbox_hd [open $LVSBOX_file "w"]

foreach lef $lefList {
    set cellList [exec grep "MACRO " $lef | awk {{print $2}}]

    foreach cell $cellList {
        if { $cell == "PAD64" } { continue }
        if { $cell == "PCORNER" } { continue }
        if [regexp {BOUNDARY_.*} $cell] { continue }
        if [regexp {FILL.*} $cell] { continue }
        if [regexp {PFILL.*} $cell] { continue }
        if [regexp {TAP.*} $cell] { continue }
        puts $hcell_hd "$cell $cell"
        puts $lvsbox_hd "LVS BOX $cell"
    }
}
close $hcell_hd
close $lvsbox_hd
