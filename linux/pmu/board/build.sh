#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Builds the board check of the PMU extensions (bitstream: make nexysvideo VIVADOCONFIG=fpganexysvideopmu in fpga/generator):
#   build.sh <buildroot output dir> <out dir> [image]
# <out dir>/pmu gets the sampling check (sampling_init.c with -DWALLY_PMU_BOARD -DWALLY_FIXED_FILTER_CHECK), the
# workload, the Smcdeleg probe module and run.sh; <out dir>/wally-nexysvideo-pmu.dtb the device tree.  With [image] it
# also writes an SD card image (../../spec/make-sd-image.sh) whose data partition holds pmu/ as /mnt/d/stage.
set -euo pipefail
[ $# -ge 2 ] || { sed -n '3,7p' "$0" | sed 's/^# \?//'; exit 1; }
BR=$(realpath "$1") OUT=$(realpath -m "$2") IMAGE=${3:-}
HERE=$(dirname "$(realpath "$0")")
CROSS=$BR/host/bin/riscv64-buildroot-linux-gnu-
KDIR=$(ls -d "$BR"/build/linux-[0-9]* | head -1)
mkdir -p "$OUT/pmu"
"${CROSS}gcc" -O2 -static -DWALLY_PMU_BOARD -DWALLY_FIXED_FILTER_CHECK -DPERF_PATH='"/usr/bin/perf"' \
    -DWORKLOAD_PATH='"./workload"' -o "$OUT/pmu/sampling" "$HERE/../sampling_init.c"
"${CROSS}gcc" -O2 -static -o "$OUT/pmu/workload" "$HERE/../branch_workload.c"
KB=$(mktemp -d); trap 'rm -rf "$KB"' EXIT
cp "$HERE/smcdeleg_probe.c" "$HERE/Kbuild" "$KB"
make -s -C "$KDIR" ARCH=riscv CROSS_COMPILE="$CROSS" M="$KB" modules
cp "$KB/smcdeleg_probe.ko" "$HERE/run.sh" "$OUT/pmu/"
"${CROSS}gcc" -O2 -static -pthread -o "$OUT/pmu/smpcheck" "$HERE/../../smp/board/smpcheck.c"   # single-hart DDR3 throughput
(cd "$HERE/../../devicetree" && dtc -q -I dts -O dtb -o "$OUT/wally-nexysvideo-pmu.dtb" wally-nexysvideo-pmu.dts)
ls -l "$OUT/pmu" "$OUT/wally-nexysvideo-pmu.dtb"
[ -z "$IMAGE" ] || "$HERE/../../spec/make-sd-image.sh" "$BR/images" "$OUT/wally-nexysvideo-pmu.dtb" "$OUT/pmu" 256 "$IMAGE"
