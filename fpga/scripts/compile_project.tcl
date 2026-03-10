open_project vivado_project/zyndra.xpr
reset_run impl_1
reset_run synth_1

launch_runs synth_1 -jobs 6
wait_on_run synth_1

launch_runs impl_1 -jobs 6
wait_on_run impl_1

launch_runs impl_1 -to_step write_bitstream -jobs 6
wait_on_run impl_1

write_hw_platform -fixed -include_bit -force -file ../yocto/hardware_description.xsa
