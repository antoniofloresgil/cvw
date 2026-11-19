#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Checkpoints of the SimPoint intervals that profile.sh chose, for Wally's buildroot configuration:
#   checkpoint.sh <profile out dir> <checkpoint dir> [warm-up instructions, default 0]
# QEMU boots the same initrd and device tree as the profile (so it executes the same instructions) with the roickpt
# plugin, which writes <checkpoint dir>/<interval>/{ram.bin,state.txt,info.txt} at the start of each chosen interval
# (warm-up instructions earlier); mkrestore.py then makes each one's bootmem.bin.  Each checkpoint runs on Wally with
#   wsim buildroot buildroot --sim verilator --args "+LinuxRam=<dir>/ram.bin +LinuxBootmem=<dir>/bootmem.bin +INSTR_LIMIT=<n>"
# ram.bin is the whole RAM (256 MiB) per checkpoint.  Environment: IMAGES, QEMU as for profile.sh.
set -euo pipefail
[ $# -ge 2 ] || { sed -n '2,10p' "$0" | sed 's/^# \?//'; exit 1; }
PROF=$(realpath "$1") OUT=$2 WARMUP=${3:-0}
HERE=$(dirname "$(realpath "$0")")
IMAGES=${IMAGES:-$RISCV/buildroot/output/images}
QEMU=${QEMU:-qemu-system-riscv64}
for f in overlay.cpio wally-virt.dtb app.simpoints app.weights qemu.log; do
    [ -f "$PROF/$f" ] || { echo "no $PROF/$f: run profile.sh first" >&2; exit 1; }
done
INTERVAL=$(grep -a -o "roibbv: ROI end .*interval [0-9]*" "$PROF/qemu.log" | grep -o "[0-9]*$")
mkdir -p "$OUT"
OUT=$(realpath "$OUT")

gcc -shared -fPIC -O2 -Wall -I"$RISCV/include" $(pkg-config --cflags glib-2.0) "$HERE/roickpt.c" -o "$OUT/libroickpt.so" $(pkg-config --libs glib-2.0)
"$QEMU" -M virt -m 256M -nographic -bios "$IMAGES/fw_jump.bin" -kernel "$IMAGES/Image" -dtb "$PROF/wally-virt.dtb" \
    -initrd "$PROF/overlay.cpio" \
    -cpu rva22s64,zicond=true,zfa=true,zfh=true,zcb=true,zbc=true,zkn=true,sstc=true,svadu=true,svnapot=true,pmp=on,debug=off \
    -icount shift=0,sleep=off \
    -plugin "$OUT/libroickpt.so,interval=$INTERVAL,warmup=$WARMUP,points=$PROF/app.simpoints,outdir=$OUT" \
    < /dev/null > "$OUT/qemu.log" 2>&1
grep -a "roickpt:" "$OUT/qemu.log"
grep -aq "roickpt: done" "$OUT/qemu.log" || { echo "not all checkpoints were taken (see $OUT/qemu.log)" >&2; exit 1; }

# the restore programs, and each interval's SimPoint weight
paste "$PROF/app.simpoints" "$PROF/app.weights" | while read -r k cluster weight cluster2; do
    echo "weight $weight" >> "$OUT/$k/info.txt"
    python3 -I "$HERE/mkrestore.py" "$OUT/$k"
done
