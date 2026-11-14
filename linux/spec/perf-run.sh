#!/bin/sh
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# On the board (BusyBox sh, root, a Linux with perf and the SBI PMU, see ../pmu/README.md): run every command of every staged benchmark under
# `perf stat` with all of Wally's counters, one CSV per run.  Made by stage.py, which puts this script and the file `events` beside the benchmarks.
#   perf-run.sh <staging directory> <results directory> [benchmark ...]
# Results: <results>/<benchmark>.<n>.csv (perf stat -x,), .err (the program's stderr), .info (exit status, seconds of wall time).
# Run on an idle system: the counters include kernel and other tasks' execution only through this task's time slices (perf counts per task),
# but timer interrupts and page faults of the benchmark itself are in.
stage=${1:?staging directory}
res=${2:?results directory}
shift 2
events=$(cat "$stage/events")
mkdir -p "$res"
[ $# -gt 0 ] || set -- $(cd "$stage" && for d in */; do [ -f "$d/cmds" ] && echo "${d%/}"; done)
for b in "$@"; do
    n=0
    while IFS= read -r cmd; do
        n=$((n + 1))
        out="$res/$b.$n"
        echo "== $b run $n: $cmd"
        t0=$(date +%s)
        (cd "$stage/$b" && eval "perf stat -x, -o '$out.csv' -e $events -- $cmd" > /dev/null 2> "$out.err")
        rc=$?
        t1=$(date +%s)
        echo "rc=$rc seconds=$((t1 - t0)) cmd=$cmd" > "$out.info"
        echo "   rc=$rc, $((t1 - t0)) s"
    done < "$stage/$b/cmds"
done
