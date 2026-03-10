# Create Vivado Project

#
# Parameters
#
set scriptdir [file dirname [file normalize [info script]]]
set rootdir [file normalize $scriptdir/..]
set _xil_proj_name_ "zyndra"

#
# Create project
#
set obj [create_project ${_xil_proj_name_} ./vivado_project -part xc7z020clg400-1 -force]
set proj_dir [get_property directory [current_project]]

set_property -name "default_lib" -value "xil_defaultlib" -objects $obj
set_property -name "enable_vhdl_2008" -value "1" -objects $obj
set_property -name "mem.enable_memory_map_generation" -value "1" -objects $obj
set_property -name "revised_directory_structure" -value "1" -objects $obj
set_property -name "simulator_language" -value "Mixed" -objects $obj
set_property -name "target_language" -value "VHDL" -objects $obj
set_property -name "xpm_libraries" -value "XPM_MEMORY" -objects $obj
set_property -name "part" -value "xc7z020clg400-1" -objects $obj
set_property -name "revised_directory_structure" -value "1" -objects $obj
set_property -name "sim.central_dir" -value "$proj_dir/${_xil_proj_name_}.ip_user_files" -objects $obj
set_property -name "sim.ip.auto_export_scripts" -value "1" -objects $obj
set_property -name "simulator_language" -value "Mixed" -objects $obj
set_property -name "sim_compile_state" -value "1" -objects $obj
set_property -name "target_language" -value "VHDL" -objects $obj
set_property -name "use_inline_hdl_ip" -value "1" -objects $obj

#
# Source files
#
set obj [get_filesets sources_1]
set files [list \
    "$rootdir/rtl/axi_master_wr.vhd"\
    "$rootdir/rtl/ad936x_txrx.vhd"\
    "$rootdir/rtl/ad936x_axi.vhd"\
    "$rootdir/rtl/top.vhd"\
]

foreach file_obj [add_files -fileset $obj $files] {
    set_property -name "file_type" -value "VHDL 2008" -objects $file_obj
}

source $rootdir/scripts/zynq_bd.tcl

set_property -name "top" -value "top" -objects $obj
set_property -name "top_auto_set" -value "0" -objects $obj

#
# Constraints
#
set obj [get_filesets constrs_1]
set files [list \
    "$rootdir/scripts/io.xdc"\
]
foreach file_obj [add_files -norecurse -fileset $obj $files] {
    set_property -name "file_type" -value "XDC" -objects $file_obj
}

#
# Simulation
#
set obj [get_filesets sim_1]
set_property -name "top" -value "top" -objects $obj
set_property -name "top_lib" -value "xil_defaultlib" -objects $obj

#
# Optimizations
#
#set_property strategy Flow_RunPhysOpt [get_runs impl_1]
#set_property strategy Flow_AlternateRoutability [get_runs synth_1]
