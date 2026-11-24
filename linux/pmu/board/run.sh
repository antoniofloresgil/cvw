#!/bin/sh
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# On the board, as root, from the directory build.sh made (on the card: sh /mnt/d/pmu/run.sh):
# the PMU extensions of fpganexysvideopmu under Linux, each step printing WALLY_* PASS or FAIL.
cd "$(dirname "$0")"
echo "== device tree and kernel"
tr '\0' ' ' < /proc/device-tree/cpus/cpu@0/riscv,isa-extensions; echo
grep -m1 isa /proc/cpuinfo
dmesg | grep -i "pmu\|sscofpmf" | head
echo "== Sscofpmf (sampling, :u/:k on programmable counters) and Smcntrpmf (:u/:k on cycles and instructions)"
./sampling
echo "sampling exit $?"
echo "== perf record of the workload, report"
perf record -e cycles:u -c 100000 -o /tmp/perf-cycles.data -- ./workload 2000000 && perf report -i /tmp/perf-cycles.data --stdio 2>/dev/null | head -20
echo "== Smcdeleg/Ssccfg"
insmod ./smcdeleg_probe.ko && dmesg | grep WALLY_SMCDELEG | tail -1   # the kernel cannot unload modules: it stays loaded until reboot
echo "== DDR3 throughput of the single hart (reference for the multicore memory system)"
./smpcheck
