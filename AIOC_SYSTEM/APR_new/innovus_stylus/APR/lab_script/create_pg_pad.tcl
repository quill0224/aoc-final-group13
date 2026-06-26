puts "User script [info script]"

create_inst -name IO_PG1    -base_cell PVDD2CDGM_V
create_inst -name IO_PG2    -base_cell PVDD2CDGM_H
create_inst -name IO_PG3    -base_cell PVDD2CDGM_V
create_inst -name IO_PG4    -base_cell PVDD2CDGM_H

create_inst -name CORE_PG1  -base_cell PVDD1CDGM_V
create_inst -name CORE_PG2  -base_cell PVDD1CDGM_H
create_inst -name CORE_PG3  -base_cell PVDD1CDGM_V
create_inst -name CORE_PG4  -base_cell PVDD1CDGM_H

create_inst -name CORNERTL  -base_cell PCORNER
create_inst -name CORNERTR  -base_cell PCORNER
create_inst -name CORNERBL  -base_cell PCORNER
create_inst -name CORNERBR  -base_cell PCORNER

# connect_pin -inst IO_PG1   -pin RTE -net io_rte
# connect_pin -inst IO_PG2   -pin RTE -net io_rte
# connect_pin -inst IO_PG3   -pin RTE -net io_rte
# connect_pin -inst IO_PG4   -pin RTE -net io_rte

# connect_pin -inst CORE_PG1 -pin RTE -net io_rte
# connect_pin -inst CORE_PG2 -pin RTE -net io_rte
# connect_pin -inst CORE_PG3 -pin RTE -net io_rte
# connect_pin -inst CORE_PG4 -pin RTE -net io_rte

# connect_pin -inst CORNERTL -pin RTE -net io_rte
# connect_pin -inst CORNERTR -pin RTE -net io_rte
# connect_pin -inst CORNERBL -pin RTE -net io_rte
# connect_pin -inst CORNERBR -pin RTE -net io_rte
