set ipmergeGds ../../outputs/CHIP.gds
set beDmGds    BEOL.gds
set feDmGds    FEOL.gds
set topCellName CHIP

set top [layout create $ipmergeGds -dt_expand -preservePaths -preserveTextAttributes -preserveProperties]

set importList ""
set importList [concat $importList  $beDmGds $feDmGds]

foreach gdsFile $importList {
    set toImport [layout create "$gdsFile" -dt_expand -preservePaths -preserveTextAttributes -preserveProperties]
    set checkTopCell [$toImport topcell]

    if {$checkTopCell == ""} {
        puts "skip $gdsFile ... due to 0 cell gds"
    } else {
        set gdsRename  [$toImport topcell] 
        $top import layout $toImport FALSE overwrite -dt_expand -preservePaths -preserveTextAttributes -preserveProperties
        $top create ref $topCellName $gdsRename 0 0 0 0 1

    }
}
## $top create layer 108.250
## $top create polygon $topCellName 108.250 0 0 891.09u 890.208u

$top gdsout CHIP_adddummmy.gds.gz $topCellName

