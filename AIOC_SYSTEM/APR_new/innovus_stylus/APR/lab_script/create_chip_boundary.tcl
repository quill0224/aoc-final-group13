# Create Chip Boundary
# 2025.10.12 Sun. Rowan Lin

puts "User script [info script]"

proc create_chip_boundary {} {
    if { [llength [get_db bumps]] == 0 } {
        puts "\nNo bump found, use create_bump_and_route first\n"
        return
    }
    delete_obj [get_db gui_rects -if {.gui_layer_name == CUSTOM_CB}]
    lassign [lindex [get_db designs .bbox] 0] left_out bottom_out right_out top_out
    lassign [lindex [get_db designs .bbox] 0] left_in bottom_in right_in top_in
    foreach bump [get_db bumps] {
        set orient [get_db $bump .orient]
        lassign [lindex [get_db $bump .bbox] 0] bllx blly burx bury
        if [regexp {\yr90\y|my90} $orient] {
            if { $bllx < $right_in } { set right_in $bllx }
            if { $burx > $right_out } { set right_out $burx }
        } elseif [regexp -nocase {r180|\ymx\y} $orient] {
            if { $blly < $top_in } { set top_in $blly }
            if { $bury > $top_out } { set top_out $bury }
        } elseif [regexp -nocase {r270|mx90} $orient] {
            if { $bllx < $left_out } { set left_out $bllx }
            if { $burx > $left_in } { set left_in $burx }
        } else {
            if { $blly < $bottom_out } { set bottom_out $blly }
            if { $bury > $bottom_in } { set bottom_in $bury }
        }
    }

    set extend 10.032
    set chip_org_lly [get_db designs .bbox.ll.y]
    set bottom_out_snap [expr round(($bottom_out-$extend-0.048)/0.096)*0.096 + $chip_org_lly]
    set top_out_snap [expr round(($top_out+$extend+0.048)/0.096)*0.096 + $chip_org_lly]
    set left_out_ext [expr $left_out-10]
    set right_out_ext [expr $right_out+10]
    create_gui_shape -layer CUSTOM_CB -rect "$left_out_ext $bottom_out_snap $right_out_ext $top_out_snap"

    set_layer_preference CUSTOM_CB -color red
    set_layer_preference CUSTOM_CB -stipple none
    puts "\n\n To stream out chip_boundary, add below line in streamOut.map\n CUSTOM_CB CUSTOM 108 250 \n\n"
}

create_chip_boundary

#draw left-bottom corner marker
#set cllx [get_db designs .bbox.ll.x]
#set clly [get_db designs .bbox.ll.y]
#create_shape -rect "[expr $cllx -16] [expr $clly -6] [expr $cllx+7] [expr $clly-3]" -layer AP
#create_shape -rect "[expr $cllx -6] [expr $clly -16] [expr $cllx-3] [expr $clly+7]" -layer AP

