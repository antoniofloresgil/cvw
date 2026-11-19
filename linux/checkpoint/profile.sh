#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# SimPoint profile of one staged SPEC benchmark (linux/spec/stage.py) on Wally's Linux in QEMU:
#   profile.sh <stage dir> <benchmark> <out dir> [interval, default 10000000] [maxK, default 30]
# QEMU (virt with Wally's device tree, deterministic -icount) boots the Linux image with the benchmark in an initrd
# that is unpacked over the built-in root file system; /etc/init.d/S99spec runs the benchmark's commands between
# roi-start and roi-end; the roibbv plugin writes the basic block vectors of that region and stops QEMU; SimPoint
# picks the intervals and their weights.  Out dir: app.bb, app.simpoints, app.weights, qemu.log (the instruction
# count since boot at the start of the region is in it: "roibbv: ROI start at instruction N"; interval k of
# app.simpoints begins N + k * interval instructions after boot).
# Environment: IMAGES (Buildroot images: fw_jump.bin, Image; default $RISCV/buildroot/output/images), SIMPOINT (default
# simpoint, from bin/installation/simpoint-install.sh), QEMU (default qemu-system-riscv64 with plugin support).
set -euo pipefail
[ $# -ge 3 ] || { sed -n '2,13p' "$0" | sed 's/^# \?//'; exit 1; }
STAGE=$(realpath "$1") BENCH=$2 OUT=$3 INTERVAL=${4:-10000000} MAXK=${5:-30}
HERE=$(dirname "$(realpath "$0")")
IMAGES=${IMAGES:-$RISCV/buildroot/output/images}
QEMU=${QEMU:-qemu-system-riscv64}
SIMPOINT=${SIMPOINT:-simpoint}
command -v "$SIMPOINT" > /dev/null || { echo "no $SIMPOINT: run bin/installation/simpoint-install.sh or set SIMPOINT" >&2; exit 1; }
[ -f "$STAGE/$BENCH/cmds" ] || { echo "no $STAGE/$BENCH/cmds" >&2; exit 1; }
mkdir -p "$OUT"
OUT=$(realpath "$OUT")

# the plugin, the two markers and the device tree
gcc -shared -fPIC -O2 -Wall -I"$RISCV/include" $(pkg-config --cflags glib-2.0) "$HERE/roibbv.c" -o "$OUT/libroibbv.so" $(pkg-config --libs glib-2.0)
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/usr/bin" "$ROOT/etc/init.d" "$ROOT/spec"
for m in start end; do
    riscv64-unknown-elf-gcc -march=rv64gc -mabi=lp64d -nostdlib -static -s -o "$ROOT/usr/bin/roi-$m" "$HERE/roi-$m.S"
done
dtc -q -I dts -O dtb "$HERE/../devicetree/wally-virt.dts" -o "$OUT/wally-virt.dtb"

# the benchmark and the script that runs it
cp -a "$STAGE/$BENCH" "$ROOT/spec/"
{
    echo '#!/bin/sh'
    echo "cd /spec/$BENCH || exit 0"
    echo 'echo "@@SPEC-START"; /usr/bin/roi-start'
    n=0
    while read -r cmd; do
        n=$((n + 1))
        echo "$cmd > /tmp/out.$n 2> /tmp/err.$n; echo \"@@SPEC-CMD $n rc=\$?\""
    done < "$STAGE/$BENCH/cmds"
    echo '/usr/bin/roi-end'
} > "$ROOT/etc/init.d/S99spec"
chmod +x "$ROOT/etc/init.d/S99spec"
# The same overlay byte for byte on every build (dates, inode numbers, order): Linux runs a different number of
# instructions before the region with different archive metadata, which would move the intervals.
(cd "$ROOT" && find . -exec touch -h -d @0 {} + && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --reproducible 2> /dev/null) > "$OUT/overlay.cpio"

# profile: the plugin stops QEMU at roi-end
"$QEMU" -M virt -m 256M -nographic -bios "$IMAGES/fw_jump.bin" -kernel "$IMAGES/Image" -dtb "$OUT/wally-virt.dtb" \
    -initrd "$OUT/overlay.cpio" \
    -cpu rva22s64,zicond=true,zfa=true,zfh=true,zcb=true,zbc=true,zkn=true,sstc=true,svadu=true,svnapot=true,pmp=on,debug=off \
    -icount shift=0,sleep=off -plugin "$OUT/libroibbv.so,interval=$INTERVAL,outfile=$OUT/app.bb" < /dev/null > "$OUT/qemu.log" 2>&1
grep -a -E "@@SPEC-CMD|roibbv:" "$OUT/qemu.log"
grep -aq "roibbv: ROI end" "$OUT/qemu.log" || { echo "the region did not end (see $OUT/qemu.log)" >&2; exit 1; }

"$SIMPOINT" -loadFVFile "$OUT/app.bb" -maxK "$MAXK" -saveSimpoints "$OUT/app.simpoints" -saveSimpointWeights "$OUT/app.weights" \
    -numInitSeeds 2 -iters 1000 -seedkm 123456 -seedproj 654321 > "$OUT/simpoint.log" 2>&1
echo "interval weight"
paste "$OUT/app.simpoints" "$OUT/app.weights" | awk '{ printf "%8d %.3f\n", $1, $3 }' | sort -n
