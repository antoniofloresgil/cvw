#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# E-Trace of Linux on the board (config fpganexysvideodbg), decoded against the kernel that runs:
#   etrace-board.sh <vmlinux> [out dir] [user program ...]
# OpenOCD (openocd-nexysvideo.cfg, etrace-capture.tcl) traces hart 0 for 0.2 s until the RAM sink is full, then our
# decoder (testbench/debug/etrace/etracedecode.py) follows the packets through the kernel's code and prints where
# the program counters fall.  With an idle system that is the kernel's idle loop and its timer interrupts; when the
# trace runs through a user program, give that program's (static) ELF too.
# Linux patches its own code at boot (alternatives, static keys), so the decoder reads the program from a copy of
# vmlinux whose .text is the one in the board's memory, read through System Bus Access (about 40 s).
set -euo pipefail
[ $# -ge 1 ] || { sed -n '3,4p' "$0" | sed 's/^# \?//'; exit 1; }
VMLINUX=$(realpath "$1") OUT=$(realpath -m "${2:-/tmp/etrace-board}")
HERE=$(dirname "$(realpath "$0")")
shift $(( $# >= 2 ? 2 : 1 ))
USER_ELFS=() && for e in "$@"; do USER_ELFS+=(--elf "$(realpath "$e")"); done
mkdir -p "$OUT"
ETRACE_WORDS=$OUT/words.txt openocd -f "$HERE/openocd-nexysvideo.cfg" -f "$HERE/etrace-capture.tcl" 2>&1 | tee "$OUT/openocd.log"
TEXT=($(riscv64-unknown-elf-readelf -SW "$VMLINUX" | awk '{for (i = 1; i < NF; i++) if ($i == ".text") print $(i+2), $(i+3), $(i+4)}'))   # address, offset, size
cat > "$OUT/dumptext.tcl" << EOF
init
catch {wally.cpu arp_examine}
riscv set_mem_access sysbus
dump_image $OUT/text.bin $(printf '0x%x' $(( 0x${TEXT[0]} - 0xffffffff80000000 + 0x80200000 ))) 0x${TEXT[2]}
if {[riscv dmi_read 0x11] & 0x200} { echo "the hart was left halted: resuming it"; catch {wally.cpu arp_poll}; catch {resume} }   ;# dmstatus.allhalted
shutdown
EOF
openocd -f "$HERE/openocd-nexysvideo.cfg" -f "$OUT/dumptext.tcl" > "$OUT/dumptext.log" 2>&1
cp "$VMLINUX" "$OUT/vmlinux-board"
dd if="$OUT/text.bin" of="$OUT/vmlinux-board" bs=1 seek=$(( 0x${TEXT[1]} )) conv=notrunc status=none
echo "$(cmp -l "$OUT/text.bin" <(tail -c +$(( 0x${TEXT[1]} + 1 )) "$VMLINUX" | head -c $(( 0x${TEXT[2]} ))) | wc -l) bytes of .text patched by the running kernel"
VMLINUX=$OUT/vmlinux-board
FULL=$(grep -q "^trRamWPLow 0x.*[13579bdf]$" "$OUT/openocd.log" && echo --full-buffer || true)   # trRamWrap: the buffer filled
python3 -c "import sys,struct; w=[int(l,16) for l in open(sys.argv[1])]; open(sys.argv[2],'wb').write(struct.pack('<%dI'%len(w),*w))" \
    "$OUT/words.txt" "$OUT/trace.bin"
python3 "$HERE/../../testbench/debug/etrace/etracedecode.py" --packets "$OUT/trace.bin" --elf "$VMLINUX" "${USER_ELFS[@]}" --xlen 64 --print $FULL \
    > "$OUT/pcs.txt"
echo "$(wc -l < "$OUT/pcs.txt") program counters decoded ($OUT/pcs.txt); the functions they fall in:"
for e in "$VMLINUX" "$@"; do nm -n "$e"; done | grep -i " [tw] " | grep -v ' \$x' | sort > "$OUT/syms.txt"
python3 - "$OUT/pcs.txt" "$OUT/syms.txt" << 'PY'
import bisect, collections, re, sys
syms = [(int(a, 16), n) for a, _, n in (l.split()[:3] for l in open(sys.argv[2]))]
addrs = [a for a, _ in syms]
count = collections.Counter()
for line in open(sys.argv[1]):
    m = re.search(r"(0x)?([0-9a-fA-F]{1,16})", line)
    if m:
        pc = int(m.group(2), 16)
        i = bisect.bisect_right(addrs, pc) - 1
        count[syms[i][1] if i >= 0 else "?"] += 1
for name, n in count.most_common(15):
    print(f"{n:8} {name}")
PY
