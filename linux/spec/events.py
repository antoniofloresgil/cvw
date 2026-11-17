# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Wally's fixed-function HPM counters as perf events, for perf-run.sh and report.py (src/privileged/pmuevents.sv, linux/pmu/events.py).

Counter n is perf's raw event r<n in hexadecimal> (r11 is counter 17); cycles is counter 0 and instructions counter 2, each on its own fixed
counter, so all of them count at once and need no multiplexing.  Counts include M, S and U execution (no :u filter without Sscofpmf).

GROUPS: the events are not all given to one `perf stat`.  Linux reprograms every event of a task through SBI calls at each context switch; with all 26
counters plus cycles and instructions on the Nexys Video (Vivado bitstream of 2026-11-16, 20 MHz) a benchmark under `perf stat` stops making progress
(the kernel preempts it again before it runs: ~43,000 involuntary context switches, no user time, found with the ILA), and with 15 events sqlite took
1205 s against 317 s on the October bitstream.  So perf-run.sh runs each command once per group of GROUP_SIZE counters, each with cycles and instructions
so that every ratio is taken inside one run."""

# perf event name -> description.  Branch-type events count retired instructions; stall events count clock cycles.
RAW = {
    3: "branches (conditional)",
    4: "jumps (not returns)",
    5: "returns",
    6: "mispredicted control transfers (any cause)",
    7: "branch direction mispredictions",
    8: "branch target mispredictions",
    9: "return address stack mispredictions",
    10: "instruction class mispredictions",
    11: "load stall cycles",
    12: "store stall cycles",
    13: "L1D accesses",
    14: "L1D misses",
    15: "L1D stall cycles",
    16: "L1I accesses",
    17: "L1I misses",
    18: "L1I stall cycles",
    19: "CSR writes",
    20: "I-cache invalidations (fence.i)",
    21: "sfence.vma",
    22: "interrupts",
    23: "exceptions",
    24: "divider busy cycles",
    25: "retired control transfers",
    26: "mispredicted retired control transfers",
}


def perf_name(counter):
    """The perf spelling of a counter: cycles, instructions, or r<hex>."""
    return {0: "cycles", 2: "instructions"}.get(counter, f"r{counter:x}")


EVENTS = [perf_name(0), perf_name(2), *(perf_name(n) for n in RAW)]

GROUP_SIZE = 6
# Related counters together (branches, other mispredictions and stalls, caches, the rest), each group with cycles and instructions.
GROUP_COUNTERS = [[3, 4, 5, 7, 25, 26], [6, 8, 9, 10, 11, 12], [13, 14, 15, 16, 17, 18], [19, 20, 21, 22, 23, 24]]
GROUPS = [[perf_name(0), perf_name(2), *(perf_name(n) for n in g)] for g in GROUP_COUNTERS]
assert sorted(n for g in GROUP_COUNTERS for n in g) == sorted(RAW) and all(len(g) <= GROUP_SIZE for g in GROUP_COUNTERS)

if __name__ == "__main__":
    print("\n".join(",".join(g) for g in GROUPS))
