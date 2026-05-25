set error_types "Metal_SameMask_Spacing"
# puts $error_types

set errors [get_db current_design .markers -if {.subtype == $error_types}]
foreach marker $errors {
    set mbox [get_db $marker .bbox]
    foreach inst [get_obj_in_area -areas $mbox -obj_type inst] {
        # puts $inst
        set llx [get_db $inst .bbox.ll.x]
        set lly [get_db $inst .bbox.ll.y]
        set urx [get_db $inst .bbox.ur.x]
        set ury [get_db $inst .bbox.ur.y]

        set bbox_list [list $llx $lly $urx $ury]
        # puts $bbox_list

        set via_set [get_obj_in_area -areas $bbox_list -obj_type special_via]
        if {[llength $via_set] > 0} {
            foreach via $via_set {
                set via_def [get_db $via .via_def]
                if {[regexp -nocase VIAGEN12 $via_def] || \
                    [regexp -nocase VIAGEN23 $via_def] || \
                    [regexp -nocase VIAGEN34 $via_def]} {
                    puts $via
                    # puts [get_db $via .top_rects]
                    delete_obj $via
                }
            }
        }


    }
}
