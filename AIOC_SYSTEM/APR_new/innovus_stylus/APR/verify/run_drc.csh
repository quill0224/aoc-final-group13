cd add_dummy
rm -rf ./log
rm -rf ./output
rm -rf ./*.gds*
./run_BE.csh 
./run_FE.csh 
./run_merge.csh
cd ../drc
rm -rf ./*.*.*
rm -rf ./LUP*
rm -rf ./log
rm -rf ./output
rm -rf ./rpt
./run_DRC.csh
