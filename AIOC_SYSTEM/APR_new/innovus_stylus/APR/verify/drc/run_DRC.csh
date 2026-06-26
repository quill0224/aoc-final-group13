#!/bin/tcsh
set DRC_Root = /usr/cad/CBDK/Executable_Package/Collaterals/Tech/DRC/N16ADFP_DRC_Calibre/

mkdir rpt output log
source /usr/cad/mentor/CIC/calibre.cshrc
source /usr/cad/mentor/CIC/license.cshrc
set NUM_OF_CPU = 128

### sed Deck
set deckFile = $DRC_Root/LOGIC_TopMr_DRC/N16ADFP_DRC_Calibre_11M.11_1a.encrypt

cp -rf $deckFile ./scr/LOGIC_TopMu_DRC
sed -i -e 's/^#DEFINE DUMMY_PRE_CHECK/\/\/#DEFINE DUMMY_PRE_CHECK/g' ./scr/LOGIC_TopMu_DRC
sed -i -e 's/\/\/#DEFINE UseprBoundary/#DEFINE UseprBoundary/g' ./scr/LOGIC_TopMu_DRC
#sed -i -e 's/#DEFINE UseprBoundary/\/\/#DEFINE UseprBoundary/g' ./scr/LOGIC_TopMu_DRC
sed -i -e 's/^LAYOUT SYSTEM/\/\/LAYOUT SYSTEM/g' ./scr/LOGIC_TopMu_DRC
sed -i -e 's/^LAYOUT PATH/\/\/LAYOUT PATH/g' ./scr/LOGIC_TopMu_DRC
sed -i -e 's/^LAYOUT PRIMARY/\/\/LAYOUT PRIMARY/g' ./scr/LOGIC_TopMu_DRC
sed -i -e 's/^DRC RESULTS DATABASE "/\/\/DRC RESULTS DATABASE "/g' ./scr/LOGIC_TopMu_DRC
sed -i -e 's/^DRC SUMMARY REPORT/\/\/DRC SUMMARY REPORT/g' ./scr/LOGIC_TopMu_DRC
sed -i -e 's/^VARIABLE VDD_TEXT/\/\/VARIABLE VDD_TEXT/g' ./scr/LOGIC_TopMu_DRC

calibre -drc -hier -64 -turbo $NUM_OF_CPU  -hyper -lmretry loop,maxretry:200,interval:200 ./scr/runset_DRC.cmd | tee -i log/runset_DRC.log
#calibre -drc -64 -lmretry loop,maxretry:200,interval:200 ./scr/runset_DRC.cmd | tee -i log/runset_DRC.log

mv -f *.density ./rpt
mv -f *.rep     ./rpt
