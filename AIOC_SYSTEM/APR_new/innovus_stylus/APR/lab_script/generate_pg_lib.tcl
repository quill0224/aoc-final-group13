# voltus -batch -file lab_script/generate_pg_lib.tcl
read_lib -lef \
    /usr/cad/CBDK/TN16/process/TN16FFC/IP/CBTK_TSMC16FFC_core_TSMC_v2.0/CIC/lef/PRTF_Innovus_N16_9M_2Xa1Xd3Xe1Z1U_UTRDL_9T_PODE.17_1a.tlef \
    /usr/cad/CBDK/TN16/process/TN16FFC/IP/CBTK_TSMC16FFC_core_TSMC_v2.0/CIC/lef/7d5t20p/tcbn16ffcllbwp7d5t20p96cpd.lef \
    /usr/cad/CBDK/TN16/process/TN16FFC/IP/CBTK_TSMC16FFC_core_TSMC_v2.0/CIC/lef/7d5t20p/tcbn16ffcllbwp7d5t20p96cpdlvt.lef \
    /usr/cad/CBDK/TN16/process/TN16FFC/IP/CBTK_TSMC16FFC_core_TSMC_v2.0/CIC/lef/7d5t20p/tcbn16ffcllbwp7d5t20p96cpdulvt.lef \
    /usr/cad/CBDK/TN16/process/TN16FFC/IP/CBTK_TSMC16FFC_core_TSMC_v2.0/CIC/lef/7d5t20p/tcbn16ffcllbwp7d5t20p96cpdmb.lef \
    /usr/cad/CBDK/TN16/process/TN16FFC/IP/CBTK_TSMC16FFC_core_TSMC_v2.0/CIC/lef/7d5t20p/tcbn16ffcllbwp7d5t20p96cpdmblvt.lef \
    /usr/cad/CBDK/TN16/process/TN16FFC/IP/CBTK_TSMC16FFC_core_TSMC_v2.0/CIC/lef/7d5t20p/tcbn16ffcllbwp7d5t20p96cpdmbulvt.lef \
    /usr/cad/CBDK/TN16/process/TN16FFC/IP/CBTK_TSMC16FFC_io_TSMC_v2.0/CIC/lef/9M_2Xa1Xd3Xe1Z1U/tphn16ffcllgv18e_univ_9lm.lef \
    /usr/cad/CBDK/TN16/process/TN16FFC/IP/CBTK_TSMC16FFC_io_TSMC_v2.0/CIC/lef/9M_2Xa1Xd3Xe1Z1U/tpbn16ffc_univ_100a_9lm_CIC.lef \
    file_preparation/lef/ts1n16ffcllulvta128x22m8swbsho_120a_m4xdh.lef \
    file_preparation/lef/ts1n16ffcllulvta128x64m8swbsho_120a_m4xdh.lef \
    file_preparation/lef/ts1n16ffcllulvta16384x32m16swbsho_120a_m4xdh.lef \
    file_preparation/lef/ts1n16ffcllulvta64x128m4swbsho_120a_m4xdh.lef \
    file_preparation/lef/ts1n16ffcllulvta64x256m2swbsho_120a_m4xdh.lef \
    file_preparation/lef/ts1n16ffcllulvta64x46m4swbsho_120a_m4xdh.lef \
    file_preparation/lef/ts1n16ffcllulvta64x47m4swbsho_120a_m4xdh.lef \
    file_preparation/lef/ts1n16ffcllulvta8192x64m8swbsho_120a_m4xdh.lef \
    file_preparation/lef/ts3n16ffcllulvta8192x64m16bo_120a_m4xdh.lef \
    file_preparation/lef/tsdn16ffcllulvta1024x64m4wbsho_130a_m4xdh.lef \
    file_preparation/lef/tsdn16ffcllulvta128x32m4wbsho_130a_m4xdh.lef \
    file_preparation/lef/tsdn16ffcllulvta2048x64m4wbsho_130a_m4xdh.lef
set_pg_library_mode -celltype techonly \
                    -power_pins {VDD 0.8 VDDPST 0.8} \
                    -ground_pins {VSS VSSPST} \
                    -extraction_tech_file ../../library/TSMC16FFC_core/CIC/RCE/QRC_1p9m_2xa1xd3xe1z1u/cworst/Tech/cworst_CCworst/qrcTechFile \
                    -temperature -40
generate_pg_library
