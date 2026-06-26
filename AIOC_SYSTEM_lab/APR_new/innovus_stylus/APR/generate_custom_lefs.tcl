set sram_lef_path "/nas0/proc/virtual/ADFP/work/Executable_Package/Collaterals/IP/sram/N16ADFP_SRAM/LEF/N16ADFP_SRAM_100a.lef"
set dest_dir "file_preparation/design"

if {![file exists $dest_dir]} {
    file mkdir $dest_dir
}

# Helper procedure to filter out unused pins from LEF macro
proc filter_lef_macro {macro_content max_q max_a} {
    set lines [split $macro_content "\n"]
    set new_lines {}
    
    set skip_pin 0
    set current_pin ""
    
    foreach line $lines {
        set trimmed [string trim $line]
        if {[string match -nocase "PIN *" $trimmed]} {
            set pin_name [lindex $trimmed 1]
            set should_skip 0
            
            # Parse pin name (e.g. Q[63] or A[5])
            if {[regexp {^([A-Za-z0-9_]+)\[([0-9]+)\]$} $pin_name match name index]} {
                if {($name eq "Q" || $name eq "D" || $name eq "BWEB") && $index > $max_q} {
                    set should_skip 1
                }
                if {$name eq "A" && $index > $max_a} {
                    set should_skip 1
                }
            }
            
            if {$should_skip} {
                set skip_pin 1
                set current_pin $pin_name
                continue
            }
        }
        
        if {$skip_pin} {
            if {[string equal -nocase $trimmed "END $current_pin"]} {
                set skip_pin 0
            }
            continue
        }
        
        lappend new_lines $line
    }
    
    return [join $new_lines "\n"]
}

puts "Reading standard LEF from $sram_lef_path..."
set fp [open $sram_lef_path r]
set file_data [read $fp]
close $fp

# Extract block for TS1N16ADFPCLLLVTA128X64M4SWSHOD
set start_tag "MACRO TS1N16ADFPCLLLVTA128X64M4SWSHOD"
set end_tag "END TS1N16ADFPCLLLVTA128X64M4SWSHOD"

set start_idx [string first $start_tag $file_data]
if {$start_idx == -1} {
    puts "Error: Could not find $start_tag in the LEF file!"
    exit 1
}

set end_idx [string first $end_tag $file_data $start_idx]
if {$end_idx == -1} {
    puts "Error: Could not find $end_tag in the LEF file!"
    exit 1
}

# Include the length of end_tag in the extracted range
set end_idx [expr {$end_idx + [string length $end_tag]}]
set macro_content [string range $file_data $start_idx $end_idx]

set lef_header "VERSION 5.8 ;\nNAMESCASESENSITIVE ON ;\nBUSBITCHARS \"\[]\" ;\nDIVIDERCHAR \"/\" ;\n"

# Generate tag_array LEF (32x32, so max_q=31, max_a=4)
puts "Generating N16ADFP_tag_array_100a.lef..."
set tag_array_content [string map {TS1N16ADFPCLLLVTA128X64M4SWSHOD TS1N16ADFPCLLLVTA128X64M4SWSHOD_tag_array} $macro_content]
set tag_array_content [filter_lef_macro $tag_array_content 31 4]
set fp [open "$dest_dir/N16ADFP_tag_array_100a.lef" w]
puts -nonewline $fp "$lef_header$tag_array_content\nEND LIBRARY\n"
close $fp

# Generate data_array LEF (32x64, so max_q=63, max_a=4)
puts "Generating N16ADFP_data_array_100a.lef..."
set data_array_content [string map {TS1N16ADFPCLLLVTA128X64M4SWSHOD TS1N16ADFPCLLLVTA128X64M4SWSHOD_data_array} $macro_content]
set data_array_content [filter_lef_macro $data_array_content 63 4]
set fp [open "$dest_dir/N16ADFP_data_array_100a.lef" w]
puts -nonewline $fp "$lef_header$data_array_content\nEND LIBRARY\n"
close $fp

puts "Processing standard SRAM LEF to avoid name conflicts..."
set fp [open $sram_lef_path r]
set std_sram_data [read $fp]
close $fp
set std_sram_data [string map {"MACRO TS1N16ADFPCLLLVTA512X45M4SWSHOD" "MACRO TS1N16ADFPCLLLVTA512X45M4SWSHOD_standard" "END TS1N16ADFPCLLLVTA512X45M4SWSHOD" "END TS1N16ADFPCLLLVTA512X45M4SWSHOD_standard"} $std_sram_data]
set fp [open "$dest_dir/N16ADFP_SRAM_100a.lef" w]
puts -nonewline $fp $std_sram_data
close $fp

# Generate custom SRAM LEF directly from the official N16ADFP_SRAM_100a.lef.
# The old SRAM.lef from the previous project has incompatible physical units,
# resulting in SIZE 1920x1391 um (wrong) vs the correct 43.025x105.552 um.
# We extract the macro block from the official LEF which already has the correct
# dimensions, pin names (BWEB[44:0], A[13:0], etc.), and metal layer geometry.
set custom_sram_dest "$dest_dir/TS1N16ADFPCLLLVTA512X45M4SWSHOD_custom.lef"
puts "Extracting TS1N16ADFPCLLLVTA512X45M4SWSHOD from official N16ADFP SRAM LEF..."
puts "  Correct physical size: 43.025 x 105.552 um"

set sram_start_tag "MACRO TS1N16ADFPCLLLVTA512X45M4SWSHOD"
set sram_end_tag   "END TS1N16ADFPCLLLVTA512X45M4SWSHOD"

set sram_start_idx [string first $sram_start_tag $file_data]
if {$sram_start_idx == -1} {
    puts "Error: Could not find MACRO TS1N16ADFPCLLLVTA512X45M4SWSHOD in official N16ADFP SRAM LEF!"
    exit 1
}
set sram_end_idx [string first $sram_end_tag $file_data $sram_start_idx]
if {$sram_end_idx == -1} {
    puts "Error: Could not find END TS1N16ADFPCLLLVTA512X45M4SWSHOD in official N16ADFP SRAM LEF!"
    exit 1
}
set sram_end_idx [expr {$sram_end_idx + [string length $sram_end_tag]}]
set sram_macro_content [string range $file_data $sram_start_idx $sram_end_idx]
set sram_macro_content [filter_lef_macro $sram_macro_content 31 13]

set fp [open $custom_sram_dest w]
puts -nonewline $fp "${lef_header}${sram_macro_content}\nEND LIBRARY\n"
close $fp
puts "Generated $custom_sram_dest successfully (official N16ADFP dimensions, correct pin names)."

puts "Done! Custom LEFs successfully generated under file_preparation/design/"
