set_db write_stream_text_size 10

if {! [file exists stream_out_map]} {
    set streamOutMap /nas0/proc/virtual/ADFP/work/Executable_Package/Collaterals/Tech/APR/N16ADFP_APR_Innovus/N16ADFP_APR_Innovus_Gdsout_11M.10a.map
    if [file exists $streamOutMap] {
       file copy $streamOutMap stream_out_map
       set outfile [open stream_out_map a]
       puts  $outfile "CUSTOM_CB CUSTOM 108 250"
       # puts  $outfile "CUSTOM_AP_high CUSTOM 74 230"
       # puts  $outfile "CUSTOM_AP_low CUSTOM  74 231"
       close $outfile
    }
}

write_stream outputs/CHIP.gds -map_file stream_out_map -lib_name DesignLib \
      -merge { \
/nas0/proc/virtual/ADFP/work/Executable_Package/Collaterals/IP/stdcell/N16ADFP_StdCell/GDS/N16ADFP_StdCell.gds \
/nas0/proc/virtual/ADFP/work/Executable_Package/Collaterals/IP/stdio/N16ADFP_StdIO/GDS/N16ADFP_StdIO.gds \
/nas0/proc/virtual/ADFP/work/Executable_Package/Collaterals/IP/bondpad/N16ADFP_BondPad/GDS/N16ADFP_BondPad.gds \
/nas0/proc/virtual/ADFP/work/Executable_Package/2025_AVSD_APR_file/gds/TS1N16ADFPCLLLVTA128X64M4SWSHOD_tag_array.gds \
/nas0/proc/virtual/ADFP/work/Executable_Package/2025_AVSD_APR_file/gds/TS1N16ADFPCLLLVTA128X64M4SWSHOD_data_array.gds \
/nas0/proc/virtual/ADFP/work/Executable_Package/2025_AVSD_APR_file/gds/TS1N16ADFPCLLLVTA512X45M4SWSHOD.gds \
} \
      -uniquify_cell_names -unit 1000 -mode all -report_file write_stream.log

#create_pin_text -cells CHIP label_loc.txt
