#!/bin/tcsh

module load calibre

set inputLvsvg  = ../../outputs/CHIP_pg.v


v2lvs -v $inputLvsvg -o ./CHIP.spi 

sed -i -e 's/^\.GLOBAL.*/**\.GLOBAL/'   ./CHIP.spi
sed -i -e 's/^XBUMP/****XBUMP/'         ./CHIP.spi
sed -i -e 's/^\.INCLUDE.*/**\.INCLUDE/' ./CHIP.spi

