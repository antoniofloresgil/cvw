#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Run Wally's checkpoints on the group's Slurm cluster (ECHO); run on the PC, with `ssh echo` open.
#   cluster.sh image                     pull the Apptainer image (Verilator's, pinned) into ~/wally/wally-sim.sif
#   cluster.sh build                     copy the sources, build the buildroot simulator in the image (once per source hash;
#                                        AFTER=<job id> waits for that job, e.g. the image's)
#   cluster.sh submit <bench>...         one array task per checkpoint of $WROOT/<bench>/ (THROTTLE, TIME, LIMIT, EXTRA;
#                                        MTIME=100: time follows the instructions, as measure.py --time-insns 100)
#   cluster.sh reference <bench>...      the whole region of each benchmark from $WROOT/<bench>-ref/0 (prepare.sh)
#   cluster.sh fetch <bench>...          bring the logs back next to the checkpoints; then measure.py <dir> reads them
#   cluster.sh status                    the jobs in the queue and the finished points
# The checkpoints (SPEC data) never leave the PC except into a node's $TMPDIR for one task: they live in
# $WROOT (default /datos/xs-logs/spec-repro/out/wally), which the cluster reads through the read-only rrsync key.
# The nodes reach the PC as $PC (default: the contents of ~/.wally-cluster-pc).
# On echo everything is under ~/wally: slurm/ (these scripts), src/<hash>/, bin/<hash>/, lists/, results/, logs/.
set -euo pipefail
[ $# -ge 1 ] || { sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 1; }
HERE=$(dirname "$(realpath "$0")")
WALLY=${WALLY:-$(realpath "$HERE/../../..")}
WROOT=${WROOT:-/datos/xs-logs/spec-repro/out/wally}
HOST=${HOST:-echo}
DIGEST=sha256:4468451a80d32c6b83a148380f0634477bd0c21417f8acce4d3237565244452e   # verilator/verilator:v5.036
R='$HOME/wally'                       # expanded on echo
THROTTLE=${THROTTLE:-16} TIME=${TIME:-2:00:00}
# user@address under which the compute nodes reach the PC (kept out of the repository)
PC=${PC:-$(cat ~/.wally-cluster-pc 2>/dev/null || true)}

remote() { ssh "$HOST" "$@"; }
scripts() { remote "mkdir -p ~/wally/slurm ~/wally/lists ~/wally/results ~/wally/logs ~/wally/src ~/wally/bin" &&
            rsync -a "$HERE"/*.sbatch "$HOST:wally/slurm/"; }
sources() { (cd "$WALLY" && { git ls-files src testbench config sim/verilator/Makefile sim/verilator/wrapper.c; \
                              ls config/deriv/buildroot/*; } | sort -u); }
srchash() { (cd "$WALLY" && sources | xargs sha256sum | sha256sum | cut -c1-12); }

case $1 in
image)
    scripts
    remote "cd ~/wally/slurm && sbatch --parsable --output=$R/logs/%x-%j.out --export=ALL,SIF=$R/wally-sim.sif,DIGEST=$DIGEST image.sbatch"
    ;;
build)
    scripts
    h=$(srchash)
    remote "mkdir -p ~/wally/src/$h"
    (cd "$WALLY" && sources | rsync -a --files-from=- . "$HOST:wally/src/$h/")
    remote "cd ~/wally/slurm && sbatch --parsable --output=$R/logs/%x-%j.out ${AFTER:+--dependency=afterok:$AFTER} \
            --export=ALL,SIF=$R/wally-sim.sif,SRC=$R/src/$h,BIN=$R/bin/$h build.sbatch"
    echo "source hash $h: the array uses ~/wally/bin/$h once the build job says BUILD OK"
    ;;
submit)
    shift; [ $# -ge 1 ] || { echo "submit <bench>..." >&2; exit 1; }
    [ -n "$PC" ] || { echo "set PC=user@address of this PC, or write it to ~/.wally-cluster-pc" >&2; exit 1; }
    h=${BUILD:-$(srchash)}
    remote "test -x ~/wally/bin/$h/Vtestbench" || { echo "no ~/wally/bin/$h/Vtestbench on $HOST: run cluster.sh build" >&2; exit 1; }
    name=$(IFS=+; echo "$*")-$(date +%Y%m%d-%H%M%S)
    list=$(mktemp)
    for b in "$@"; do
        for d in "$WROOT/$b"/*/; do
            [ -f "$d/info.txt" ] && [ -f "$d/ram.bin" ] && [ -f "$d/bootmem.bin" ] && echo "$b/$(basename "$d")"
        done
    done | sort -t/ -k1,1 -k2,2n > "$list"
    n=$(wc -l < "$list"); [ "$n" -gt 0 ] || { echo "no checkpoints under $WROOT/{$*}" >&2; exit 1; }
    scripts
    rsync -a "$list" "$HOST:wally/lists/$name.txt"; rm -f "$list"
    remote "cd ~/wally/slurm && sbatch --parsable --array=1-$n%$THROTTLE --time=$TIME \
            --output=$R/logs/%x-%A_%a.out \
            --export=ALL,PC=$PC,LIST=$R/lists/$name.txt,SIF=$R/wally-sim.sif,BIN=$R/bin/$h,RES=$R/results,LIMIT=${LIMIT:-},EXTRA='${EXTRA:-}',MTIME=${MTIME:-} \
            array.sbatch"
    echo "$n tasks ($name), at most $THROTTLE at once"
    ;;
reference)
    # the whole region from the checkpoint of its start ($WROOT/<bench>-ref/0, prepare.sh), in whole intervals, with
    # the counters every interval; the time limit assumes 60 K instructions per second (a node ran 66 K) and adds 50 %
    shift
    for b in "$@"; do
        info=$WROOT/$b-ref/0/info.txt
        [ -f "$info" ] || { echo "no $info: run prepare.sh" >&2; exit 1; }
        I=$(awk '$1 == "interval" {print $2}' "$info"); N=$(awk '$1 == "region_instructions" {print $2}' "$info")
        l=$(( N / I * I )); h=$(( l * 3 / 2 / 60000 / 3600 + 1 ))
        echo "$b: $l instructions, time limit $h h"
        LIMIT=$l EXTRA=+HPM_PERIOD=$I TIME=$h:00:00 "$0" submit "$b-ref"
    done
    ;;
fetch)
    shift
    for b in "$@"; do
        rsync -a --include='*/' --include=wsim.log --include=uart.out --include=time.log --include=DONE --exclude='*' \
            "$HOST:wally/results/$b/" "$WROOT/$b/"
        echo "$b: $(ls "$WROOT/$b"/*/DONE 2>/dev/null | wc -l) points done"
    done
    ;;
status)
    remote 'squeue -u $USER -h -o "%.18i %.12j %.8T %.10M %R" | grep -i wally; for b in ~/wally/results/*/; do
            [ -d "$b" ] && echo "$(basename "$b"): $(ls "$b"/*/DONE 2>/dev/null | wc -l) done"; done' || true
    ;;
*)
    echo "unknown command $1" >&2; exit 1
    ;;
esac
