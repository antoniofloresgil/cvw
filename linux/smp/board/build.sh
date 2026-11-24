#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# The SD card of the multicore Nexys Video (config fpganexysvideosmp, docs/fpga-multicore.md):
#   build.sh <buildroot output dir> <SMP kernel Image> <out dir> [image]
# The board's Buildroot kernel has no SMP: build a copy of it with CONFIG_SMP (the commands are in docs/fpga-multicore.md).
# <out dir>/smp gets smpcheck (smpcheck.c) and run.sh, <out dir>/wally-nexysvideo-smp.dtb the device tree; with [image]
# also the card's image (../../spec/make-sd-image.sh): OpenSBI of <buildroot>, the SMP kernel, smp/ as /mnt/d/stage.
set -euo pipefail
[ $# -ge 3 ] || { sed -n '3,7p' "$0" | sed 's/^# \?//'; exit 1; }
BR=$(realpath "$1") KERNEL=$(realpath "$2") OUT=$(realpath -m "$3") IMAGE=${4:-}
HERE=$(dirname "$(realpath "$0")")
mkdir -p "$OUT/smp" "$OUT/images"
"$BR/host/bin/riscv64-buildroot-linux-gnu-gcc" -O2 -static -pthread -o "$OUT/smp/smpcheck" "$HERE/smpcheck.c"
cp "$HERE/run.sh" "$OUT/smp/"
(cd "$HERE/../../devicetree" && dtc -q -I dts -O dtb -o "$OUT/wally-nexysvideo-smp.dtb" wally-nexysvideo-smp.dts)
cp "$BR/images/fw_jump.bin" "$OUT/images/"; cp "$KERNEL" "$OUT/images/Image"
ls -l "$OUT/smp" "$OUT/wally-nexysvideo-smp.dtb"
[ -z "$IMAGE" ] || "$HERE/../../spec/make-sd-image.sh" "$OUT/images" "$OUT/wally-nexysvideo-smp.dtb" "$OUT/smp" 256 "$IMAGE"
