#!/bin/tcsh
mkdir log output
source /usr/cad/mentor/CIC/calibre.cshrc
source /usr/cad/mentor/CIC/license.cshrc

##merge
calibredrv -64 ./scr/runset_merge.cmd | tee log/runset_merge.log

