# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Checks of the JTAG debug port through OpenOCD (run by "make openocd" with openocd.cfg):
# load a program into RAM with System Bus Access while hartreset holds the hart, read it back,
# release the hart and read the 42 it writes to the GPIOs.

set errors 0
proc check {what got expected} {
    global errors
    if {$got != $expected} {
        echo [format "FAIL: %s: 0x%08x, expected 0x%08x" $what $got $expected]
        incr errors
    } else {
        echo [format "ok   %s: 0x%08x" $what $got]
    }
}
proc dmr {addr} { return [expr {[riscv dmi_read $addr]}] }
proc dmw {addr value} { riscv dmi_write $addr $value }
proc sbwait {} {
    while {[expr {[dmr 0x38] & (1 << 21)}]} {}
}

init
# Examining the target reads dtmcs and sets up the Debug Module; it then fails to halt the hart
# (no debug mode yet), but the DMI commands work from then on
catch {wally.cpu arp_examine}

check "dmstatus.version" [expr {[dmr 0x11] & 0xF}] 3
# make NHARTS=n passes the number of harts: hold them all, hart 0 last (it stays selected)
set nharts 1
if {[info exists ::env(NHARTS)]} { set nharts $::env(NHARTS) }
dmw 0x10 0x1
for {set h 1} {$h < $nharts} {incr h} { dmw 0x10 [expr {0x20000001 | ($h << 16)}] }
dmw 0x10 0x20000001                       ;# hartreset
check "dmstatus.allunavail" [expr {([dmr 0x11] >> 13) & 1}] 1

# The program of debug_tb.sv: GPIOs to 42, a signature at 0x80001000, loop
set program {0x100602b7 0x0ff00313 0x0062a423 0x02a00313 0x0062a623
             0x00001397 0x600dc337 0x0de30313 0xfe63a623 0x0000006f}
dmw 0x38 [expr {(2 << 17) | (1 << 16)}]   ;# 32-bit accesses, auto-increment
dmw 0x39 0x80000000
foreach word $program {
    dmw 0x3c $word
    sbwait
}
dmw 0x38 [expr {(1 << 20) | (2 << 17) | (1 << 16) | (1 << 15)}]   ;# read on address and data
dmw 0x39 0x80000000
set i 0
foreach word $program {
    sbwait
    check "program word $i" [dmr 0x3c] $word
    incr i
}
sbwait
check "sberror" [expr {([dmr 0x38] >> 12) & 7}] 0

for {set h 1} {$h < $nharts} {incr h} { dmw 0x10 [expr {0x10000001 | ($h << 16)}] }
dmw 0x10 0x10000001                       ;# release the hart, acknowledge havereset
check "dmstatus.allrunning" [expr {([dmr 0x11] >> 11) & 1}] 1
dmw 0x38 [expr {(1 << 20) | (2 << 17)}]
dmw 0x39 0x1006000c                       ;# GPIO output_val
sbwait
check "GPIO output_val written by the program" [dmr 0x3c] 42

if {$errors == 0} {
    echo "SUCCESS! All tests ran without failures."
    shutdown
} else {
    echo "FAIL: $errors checks failed"
    shutdown error
}
