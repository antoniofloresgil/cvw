# The E-Trace of hart 0 on the board (config fpganexysvideodbg) through System Bus Access, while Linux runs: the
# sequence of docs/trace.md, the sink stopping when its buffer is full (trRamStopOnWrap), then the buffer's words
# into $::env(ETRACE_WORDS), one hexadecimal word per line.  etrace-board.sh runs it and decodes the words.
proc dmr {a} { return [expr {[riscv dmi_read $a]}] }
proc dmw {a v} { riscv dmi_write $a $v }
proc sbwait {} { while {[expr {[dmr 0x38] & (1 << 21)}]} {} }
proc sbw {addr value} { dmw 0x38 [expr {(2 << 17)}]; dmw 0x39 $addr; dmw 0x3c $value; sbwait }
proc sbr {addr} { dmw 0x38 [expr {(1 << 20) | (2 << 17)}]; dmw 0x39 $addr; sbwait; return [dmr 0x3c] }
set te 0x04000000
set sink 0x04001000
init
catch {wally.cpu arp_examine}
echo "trTeImpl 0x[format %08x [sbr [expr {$te + 4}]]] trRamImpl 0x[format %08x [sbr [expr {$sink + 4}]]] trRamLimitLow 0x[format %08x [sbr [expr {$sink + 0x18}]]]"
sbw $sink 1
sbw [expr {$sink + 0x20}] 0
sbw $sink [expr {3 | (1 << 8)}]
sbw $te 1
sbw $te 0x00010037
sleep 200
sbw $te 0x00010031
while {!([sbr $te] & 8)} {}
echo "trTeControl 0x[format %08x [sbr $te]] (bit 22 trTeInstStallOrOverflow: a packet was dropped)"
sbw $sink 1
while {!([sbr $sink] & 8)} {}
set wp [sbr [expr {$sink + 0x20}]]
echo "trRamWPLow 0x[format %08x $wp]"
set words [expr {($wp & ~3) / 4}]
if {$wp & 1} { set words [expr {([sbr [expr {$sink + 0x18}]] + 4) / 4}] }
sbw [expr {$sink + 0x28}] 0
set f [open $::env(ETRACE_WORDS) w]
for {set i 0} {$i < $words} {incr i} { puts $f [format %08x [sbr [expr {$sink + 0x40}]]] }
close $f
echo "$words words of trace"
sbw $te 0
sbw $sink 0
if {[riscv dmi_read 0x11] & 0x200} { echo "the hart was left halted: resuming it"; catch {wally.cpu arp_poll}; catch {resume} }   ;# dmstatus.allhalted
shutdown
