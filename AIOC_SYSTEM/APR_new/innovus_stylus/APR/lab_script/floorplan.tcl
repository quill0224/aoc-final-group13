# Floorplan
# 2025.06.19 Thu. Rowan Lin

puts "User script [info script]"

#========================================================================================================================================================================#

# Step 1: specify floorplan

read_io_file file_preparation/design/CHIP.io

# create_floorplan -site core -core_density_size H/W_ratio utilization core_to_left core_to_top core_to_right core_to_bottom (Core to I/O bound)
# create_floorplan -site core -core_density_size 1 0.7 80.0 80.0 80.0 80.0

create_floorplan -site core -die_size 1854 1854 80 80 80 80

#========================================================================================================================================================================#

# Step 2: place I/O

# Read I/O information and use the die size provided buy the user, without allowing the tool to adjust it automaticlly
read_io_file file_preparation/design/CHIP.io -no_die_size_adjust

# Align floorplan grid
snap_floorplan -all

# Swap I/O
# This step is used to swap H/L/V pads to achieve HV-side symmetry, typically for IO ring alignment correction.
source -quiet lab_script/swap_io_hv.tcl

do_swap_io

# Read I/O information and use the die size provided buy the user, without allowing the tool to adjust it automaticlly
# read_io_file file_preparation/design/CHIP.io -no_die_size_adjust

# create_floorplan -site core -box_size 0.0 0.0 1455.408 1455.408 50.04 49.968 1405.368 1405.368 130.05 129.984 1325.358 1325.184

create_floorplan -site core -box_size 0.0 0.0 1854.0 1854.0 50.04 49.968 1803.96 1803.96 130.05 129.984 1723.95 1723.944

# Read I/O information and use the die size provided buy the user, without allowing the tool to adjust it automaticlly
read_io_file file_preparation/design/CHIP.io -no_die_size_adjust

# Align floorplan grid
snap_floorplan -all

check_floorplan

# Add I/O fillers
source -quiet lab_script/add_io_fillers.tcl

# Fix I/O pads
set_db  [get_db insts -if {.base_cell.base_class == pad}] .place_status  fixed

write_db dbs/02_place_io.enc

#========================================================================================================================================================================#

# Create bumps

source -quiet lab_script/create_bump.tcl
source -quiet lab_script/delete_bump.tcl

#========================================================================================================================================================================#

# Step 3: place hard macros

source -quiet lab_script/set_macro_place_constraint.tcl

# Place hard macros
#source -quiet lab_script/place_hard_macro.tcl

# Fix the hard macros, and the position will no longer be changed
set_instance_placement_status -all_hard_macros -status fixed

delete_relative_floorplan -all

set_db finish_floorplan_active_objs [list core macro macro_halo soft_blockage]
finish_floorplan -fill_place_blockage soft 20.0

#========================================================================================================================================================================#

# Step 4: save file
write_db dbs/03_floorplan.enc
