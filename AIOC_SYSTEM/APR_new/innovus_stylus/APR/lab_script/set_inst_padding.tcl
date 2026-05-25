# Metal_SameMask_Spacing
set error_types {Metal_Short Metal_SameMask_Spacing Metal_EndOfLine_SameMask_spacing Metal_EndOfLine_Spacing}

foreach error_type $error_types {
    puts $error_type
    set errors [get_db current_design .markers -if {.subtype == $error_type}]
    foreach marker $errors {
       #puts $marker
        set mbox [get_db $marker .bbox]
        foreach inst [get_obj_in_area -areas $mbox -obj_type inst] {
            set inst_trimmed [string range $inst 10 end]  ;# "inst:CHIP/" has 10 characters
            puts $inst_trimmed
            set_inst_padding -inst $inst_trimmed -right_side 2 -left_side 2
        }
    }
}

# check if the inst padding is set correctly
# report_inst_padding -all