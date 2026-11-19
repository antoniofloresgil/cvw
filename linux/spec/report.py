#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Turn the CSVs of perf-run.sh (perf stat -x,) into a table per benchmark: instructions, cycles, CPI and the rates that do not depend on the clock
(misses and mispredictions per thousand instructions).  The runs of one benchmark are summed.

Why MPKI and not only CPI: on the FPGA the core runs at tens of MHz against a DDR3 that answers in a few core cycles, so a miss costs far fewer cycles than on a
fast chip and CPI understates the memory stalls; misses and mispredictions per instruction do not depend on the clock.
Standard library only:   report.py <results directory> [--markdown]"""

import argparse
import csv
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from events import perf_name

CYC, INS = perf_name(0), perf_name(2)
BR, JMP, RET, MISP, DIRW = (perf_name(n) for n in (3, 4, 5, 26, 7))
L1D_A, L1D_M, L1I_A, L1I_M = (perf_name(n) for n in (13, 14, 16, 17))
LD_STALL, ST_STALL, DC_STALL, IC_STALL = (perf_name(n) for n in (11, 12, 15, 18))


def read_csv(path):
    """event -> (count, percent of time counted); events that were not counted are left out."""
    out = {}
    for row in csv.reader(line for line in path.read_text().splitlines() if line and not line.startswith("#")):
        if len(row) < 3 or not row[0].strip().isdigit():
            continue
        pct = float(row[4]) if len(row) > 4 and row[4] else 100.0
        out[row[2].split(":")[0]] = (int(row[0]), pct)
    return out


NAME = re.compile(r"^(?P<bench>.+)\.(?P<run>\d+)(?:\.g(?P<group>\d+))?\.csv$")


def collect(results):
    """bench -> group -> event -> count summed over the runs of the benchmark.  perf-run.sh runs each command once per group of counters (events.py), each group with
    cycles and instructions, so every ratio below is taken inside one group; CSVs of an older single run have no group (group 0)."""
    totals = defaultdict(lambda: defaultdict(lambda: defaultdict(int)))
    flags = defaultdict(set)
    for p in sorted(results.glob("*.csv")):
        m = NAME.match(p.name)
        if not m:
            continue
        bench, group = m["bench"], int(m["group"] or 0)
        info = p.with_suffix(".info")
        if info.exists() and not info.read_text().startswith("rc=0"):
            flags[bench].add("exit status not 0")
        ev = read_csv(p)
        for name in (CYC, INS):
            if name not in ev:
                flags[bench].add(f"{name} missing")
        for name, (count, pct) in ev.items():
            totals[bench][group][name] += count
            if pct < 99.9:
                flags[bench].add(f"{name} multiplexed ({pct:.0f} %)")
    for bench, groups in totals.items():
        ins = [g[INS] for g in groups.values() if g.get(INS)]
        if ins and max(ins) > 1.05 * min(ins):
            flags[bench].add(f"instructions differ {100 * (max(ins) / min(ins) - 1):.0f} % between groups")
    return totals, flags


def rate(groups, name, base, scale=1.0):
    """scale * event / base, from the first group that counted the event with a non-zero base."""
    for g in groups.values():
        if name in g and g.get(base):
            return scale * g[name] / g[base]
    return None


def per_k(groups, name):
    r = rate(groups, name, INS, 1000)
    return "-" if r is None else f"{r:.2f}"


def pct_of(groups, name, base):
    r = rate(groups, name, base, 100)
    return "-" if r is None else f"{r:.1f}"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("results", type=Path)
    args = ap.parse_args()
    totals, flags = collect(args.results)
    cols = ["benchmark", "instr (M)", "cycles (M)", "CPI", "br/instr %", "mispred MPKI", "dir MPKI", "L1I MPKI", "L1D MPKI", "L1D miss %", "load stall %", "I$ stall %", "notes"]
    print("| " + " | ".join(cols) + " |")
    print("|" + "---|" * len(cols))
    for bench in sorted(totals):
        groups = totals[bench]
        first = groups[min(groups)]
        if not first.get(INS):
            print(f"| {bench} | no instructions counted |" + " |" * (len(cols) - 2))
            continue
        row = [
            bench,
            f"{first[INS] / 1e6:.1f}",
            f"{first.get(CYC, 0) / 1e6:.1f}",
            f"{first[CYC] / first[INS]:.2f}" if first.get(CYC) else "-",
            pct_of(groups, BR, INS),
            per_k(groups, MISP),
            per_k(groups, DIRW),
            per_k(groups, L1I_M),
            per_k(groups, L1D_M),
            pct_of(groups, L1D_M, L1D_A),
            pct_of(groups, LD_STALL, CYC),
            pct_of(groups, IC_STALL, CYC),
            "; ".join(sorted(flags[bench])),
        ]
        print("| " + " | ".join(row) + " |")


if __name__ == "__main__":
    main()
