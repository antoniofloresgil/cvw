# Checks of the JTAG debug port on the board, while Linux runs (openocd -f openocd-nexysvideo.cfg -f debug-check.tcl):
# examine the hart, halt it, read its registers and a CSR, step it, read memory through the hart and through
# System Bus Access, resume it.  Prints SUCCESS or FAIL lines like openocd_test.tcl.
set errors 0
proc fail {what} { global errors; echo "FAIL: $what"; incr errors }
init
wally.cpu arp_examine
echo "dmstatus 0x[format %08x [riscv dmi_read 0x11]]"
halt
set pc [lindex [reg pc] 2]
echo "halted at pc $pc"
set misa [lindex [reg misa] 2]
echo "misa $misa"
if {(($misa >> 62) & 3) != 2} { fail "misa.MXL of $misa is not 64 bits" }
set priv [lindex [reg priv] 2]
echo "priv $priv"
step
set pc2 [lindex [reg pc] 2]
echo "after one step pc $pc2"
if {$pc2 == $pc} { fail "step did not move the pc" }
# the kernel's first words at 0x80200000 (OpenSBI fw_jump loads it there), through the hart and through the bus
riscv set_mem_access progbuf
set viahart [read_memory 0x80200000 32 4 phys]
riscv set_mem_access sysbus
set viabus [read_memory 0x80200000 32 4 phys]
echo "kernel image via the hart: $viahart, via System Bus Access: $viabus"
if {$viahart ne $viabus} { fail "memory reads differ" }
resume
sleep 500
halt
set pc3 [lindex [reg pc] 2]
echo "halted again at pc $pc3"
resume
if {$errors == 0} { echo "SUCCESS! All tests ran without failures." } else { echo "FAIL: $errors errors" }
shutdown
