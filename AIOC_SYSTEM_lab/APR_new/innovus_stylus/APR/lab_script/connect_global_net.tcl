puts "User script [info script]"

connect_global_net VDD -type pg_pin -pin_base_name VDD -inst_base_name *
connect_global_net VSS -type pg_pin -pin_base_name VSS -inst_base_name *
connect_global_net VDD -type pg_pin -pin_base_name VPP -inst_base_name *
connect_global_net VSS -type pg_pin -pin_base_name VBB -inst_base_name *
connect_global_net VDDPST -type pg_pin -pin_base_name VDDPST -inst_base_name *
# connect_global_net VDD -type pg_pin -pin_base_name VDDPE -inst_base_name *
# connect_global_net VDD -type pg_pin -pin_base_name VDDCE -inst_base_name *
# connect_global_net VSSPST -type pg_pin -pin_base_name VSSPST -inst_base_name *
# connect_global_net VSS -type pg_pin -pin_base_name VSSE -inst_base_name *
connect_global_net VDD -type tie_hi -inst_base_name *
connect_global_net VSS -type tie_lo -inst_base_name *

# if {[llength [get_db nets ESD]] == 0} {
#     create_net -physical -ground -name ESD
# }
# if {[llength [get_db nets POCCTRL]] == 0} {
#     create_net -physical -ground -name POCCTRL
# }
# connect_global_net ESD -type pg_pin -pin_base_name ESD -inst_base_name *
# connect_global_net POCCTRL -type pg_pin -pin_base_name POCCTRL -inst_base_name *

# set_db net:ESD .skip_routing true
# set_db net:POCCTRL .skip_routing true

 
