#!/bin/tcsh

mkdir log output rpt

source /usr/cad/mentor/CIC/calibre.cshrc

set NUM_OF_CPU = 12

tclsh ./scr/genHcell.cmd > ./rpt/hcell

### sed Deck
set ProjRoot = /usr/cad/CBDK

set deckFile = "$ProjRoot/Executable_Package/Collaterals/Tech/LVS/N16ADFP_LVS_Calibre/MAIN_DECK/CCI_FLOW/N16ADFP_LVS_Calibre"

cp -rf $deckFile ./scr/N16ADFP_LVS_Calibre.modified

sed -i -e 's/VARIABLE POWER_NAME/\/\/VARIABLE POWER_NAME/g' ./scr/N16ADFP_LVS_Calibre.modified
sed -i -e 's/VARIABLE GROUND_NAME/\/\/VARIABLE GROUND_NAME/g' ./scr/N16ADFP_LVS_Calibre.modified

sed -i -e 's/LAYOUT PRIMARY/\/\/LAYOUT PRIMARY/g' ./scr/N16ADFP_LVS_Calibre.modified
sed -i -e 's/LAYOUT PATH/\/\/LAYOUT PATH/g' ./scr/N16ADFP_LVS_Calibre.modified
sed -i -e 's/LAYOUT SYSTEM/\/\/LAYOUT SYSTEM/g' ./scr/N16ADFP_LVS_Calibre.modified

sed -i -e 's/SOURCE PRIMARY/\/\/SOURCE PRIMARY/g' ./scr/N16ADFP_LVS_Calibre.modified
sed -i -e 's/SOURCE PATH/\/\/SOURCE PATH/g' ./scr/N16ADFP_LVS_Calibre.modified

sed -i -e 's/ERC RESULTS DATABASE/\/\/ERC RESULTS DATABASE/g' ./scr/N16ADFP_LVS_Calibre.modified
sed -i -e 's/ERC SUMMARY REPORT/\/\/ERC SUMMARY REPORT/g' ./scr/N16ADFP_LVS_Calibre.modified

sed -i -e 's/LVS REPORT \"/\/\/LVS REPORT \"/g' ./scr/N16ADFP_LVS_Calibre.modified

calibre 	 -hcell ./rpt/hcell -64 -hier -turbo $NUM_OF_CPU -hyper -spice  ./output/N16_ADFP.layspi ./scr/runset.cmd  -lmretry loop,maxretry:200,interval:180 | tee -i log/runset.ext.log
calibre -lvs -hcell ./rpt/hcell -64 -hier -turbo $NUM_OF_CPU -hyper -layout ./output/N16_ADFP.layspi ./scr/runset.cmd -lmretry loop,maxretry:200,interval:180 | tee -i log/runset.log

