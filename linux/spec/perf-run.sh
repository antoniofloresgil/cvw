#!/bin/sh
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# On the board (BusyBox sh without $((...)) arithmetic, so expr is used, root, a Linux with perf and the SBI PMU, see ../pmu/README.md): run every command of every staged benchmark under
# `perf stat` with Wally's counters, one CSV per run and group of counters.  Made by stage.py, which puts this script and the file `events` beside the benchmarks.
#   perf-run.sh <staging directory> <results directory> [benchmark ...]
# `events` has one line per group of counters (events.py says why not all at once): every command runs once per line, so a benchmark takes as long as there are groups.
# Results: <results>/<benchmark>.<n>.g<k>.csv (perf stat -x,: the counters of group k; group 1 also has the software events task-clock, page-faults, context-switches, cpu-migrations),
# .out (the program's stdout, to compare with SPEC's reference output), .err (its stderr), .info (exit status, seconds of wall time), the same names with .g<k>.
# Run on an idle system: the counters include kernel and other tasks' execution only through this task's time slices (perf counts per task),
# but timer interrupts and page faults of the benchmark itself are in.
stage=${1:?staging directory}
res=${2:?results directory}
shift 2
groups=$(cat "$stage/events")
mkdir -p "$res"
[ $# -gt 0 ] || set -- $(cd "$stage" && for d in */; do [ -f "$d/cmds" ] && echo "${d%/}"; done)
for b in "$@"; do
    n=0
    while IFS= read -r cmd; do
        n=$(expr $n + 1)
        g=0
        for events in $groups; do
            g=$(expr $g + 1)
            out="$res/$b.$n.g$g"
            sw=
            [ $g -eq 1 ] && sw=,task-clock,page-faults,context-switches,cpu-migrations
            echo "== $b run $n group $g: $cmd"
            t0=$(date +%s)
            (cd "$stage/$b" && eval "perf stat -x, -o '$out.csv' -e $events$sw -- $cmd" > "$out.out" 2> "$out.err")
            rc=$?
            t1=$(date +%s)
            echo "rc=$rc seconds=$(expr $t1 - $t0) cmd=$cmd" > "$out.info"
            echo "   rc=$rc, $(expr $t1 - $t0) s"
        done
    done < "$stage/$b/cmds"
done
