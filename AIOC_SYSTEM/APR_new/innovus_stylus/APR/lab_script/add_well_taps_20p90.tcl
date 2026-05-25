puts "User script [info script]"

set_db add_well_taps_insert_cells  {TAPCELLBWP20P90 rule 50.76}
add_well_taps -checker_board

# check DRC
set_db check_drc_limit 100000
check_drc
# If there is any error, fix it
fix_via -min_step
# check again, the drc will be zero
check_drc

write_db dbs/11_add_welltap.enc
