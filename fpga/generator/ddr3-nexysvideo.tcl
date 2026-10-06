set partNumber $::env(XILINX_PART)
set boardName $::env(XILINX_BOARD)
set ipName ddr3

if {[info exists ::env(XILINX_BOARD_REPO)]} {
    set_param board.repoPaths $::env(XILINX_BOARD_REPO)
}

create_project $ipName . -force -part $partNumber
set_property board_part $boardName [current_project]
create_ip -name mig_7series -vendor xilinx.com -library ip -module_name $ipName

set migDir $ipName.srcs/sources_1/ip/$ipName
file mkdir $migDir
set sourceMig ../../../addins/vivado-boards/new/board_files/nexys_video/A.0/1.2/mig.prj
set input [open $sourceMig r]
set migConfig [read $input]
close $input
set migConfig [string map [list \
    {<SystemClock>Single-Ended</SystemClock>} {<SystemClock>No Buffer</SystemClock>} \
    {<C0_S_AXI_DATA_WIDTH>32</C0_S_AXI_DATA_WIDTH>} {<C0_S_AXI_DATA_WIDTH>64</C0_S_AXI_DATA_WIDTH>} \
    {<C0_S_AXI_ID_WIDTH>2</C0_S_AXI_ID_WIDTH>} {<C0_S_AXI_ID_WIDTH>4</C0_S_AXI_ID_WIDTH>}] $migConfig]
set output [open $migDir/nexys-video-mig.prj w]
puts -nonewline $output $migConfig
close $output

set_property -dict [list CONFIG.XML_INPUT_FILE {nexys-video-mig.prj} CONFIG.RESET_BOARD_INTERFACE {Custom} CONFIG.MIG_DONT_TOUCH_PARAM {Custom} CONFIG.BOARD_MIG_PARAM {Custom}] [get_ips $ipName]

generate_target {instantiation_template} [get_files ./$ipName.srcs/sources_1/ip/$ipName/$ipName.xci]
generate_target all [get_files ./$ipName.srcs/sources_1/ip/$ipName/$ipName.xci]
create_ip_run [get_files -of_objects [get_fileset sources_1] ./$ipName.srcs/sources_1/ip/$ipName/$ipName.xci]
launch_run -jobs 8 ${ipName}_synth_1
wait_on_run ${ipName}_synth_1
