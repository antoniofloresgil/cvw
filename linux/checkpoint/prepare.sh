#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Everything the PC does for one benchmark before the cluster runs it:
#   prepare.sh <stage dir> <benchmark> [interval, default 10000000]
# profile.sh -> $PROFROOT/<benchmark>/, the checkpoints of SimPoint's intervals -> $WROOT/<benchmark>/<k>/, and the
# checkpoint of the start of the region -> $WROOT/<benchmark>-ref/0/ (for the whole-region run; its info.txt also
# gets region_instructions).  Then on the cluster: cluster/cluster.sh submit <benchmark> and reference <benchmark>.
# Environment: IMAGES as for profile.sh; WROOT (default /datos/xs-logs/spec-repro/out/wally, read by the cluster),
# PROFROOT (default /datos/tmp/ckpt/prof).  Stops if a command of the benchmark did not end with rc=0 in QEMU.
set -euo pipefail
[ $# -ge 2 ] || { sed -n '2,9p' "$0" | sed 's/^# \?//'; exit 1; }
STAGE=$1 BENCH=$2 INTERVAL=${3:-10000000}
HERE=$(dirname "$(realpath "$0")")
WROOT=${WROOT:-/datos/xs-logs/spec-repro/out/wally}
PROFROOT=${PROFROOT:-/datos/tmp/ckpt/prof}
P=$PROFROOT/$BENCH
mkdir -p "$PROFROOT" "$WROOT"

[ -f "$P/app.simpoints" ] || "$HERE/profile.sh" "$STAGE" "$BENCH" "$P" "$INTERVAL"
if grep -a "@@SPEC-CMD" "$P/qemu.log" | grep -qv "rc=0"; then
    echo "$BENCH: a command failed in QEMU:" >&2; grep -a "@@SPEC-CMD" "$P/qemu.log" >&2; exit 1
fi
grep -aq "roibbv: ROI end" "$P/qemu.log" || { echo "$BENCH: the region did not end (see $P/qemu.log)" >&2; exit 1; }
REGION=$(grep -a -o "[0-9]* in the ROI" "$P/qemu.log" | grep -o "^[0-9]*")

[ -f "$WROOT/$BENCH/.done" ] || { "$HERE/checkpoint.sh" "$P" "$WROOT/$BENCH" && touch "$WROOT/$BENCH/.done"; }
if [ ! -f "$WROOT/$BENCH-ref/.done" ]; then
    echo "0 0" > "$P/ref.points"
    POINTS=$P/ref.points "$HERE/checkpoint.sh" "$P" "$WROOT/$BENCH-ref"
    echo "region_instructions $REGION" >> "$WROOT/$BENCH-ref/0/info.txt"
    touch "$WROOT/$BENCH-ref/.done"
fi
rm -f "$WROOT/$BENCH/libroickpt.so" "$WROOT/$BENCH-ref/libroickpt.so"
echo "$BENCH: region $REGION instructions, $(wc -l < "$P/app.simpoints") points"
