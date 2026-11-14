#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Turn the CSVs of perf-run.sh (perf stat -x,) into a table per benchmark: instructions, cycles, CPI and the rates that do not depend on the clock
(misses and mispredictions per thousand instructions).  The runs of one benchmark are summed.

Why MPKI and not only CPI: on the FPGA the core runs at tens of MHz against a DDR3 that answers in a few core cycles, so a miss costs far fewer cycles than on a
fast chip and CPI understates the memory stalls; misses and mispredictions per instruction do not depend on the clock.
Standard library only:   report.py <results directory> [--markdown]"""

import argparse
import csv
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


def collect(results):
    totals = defaultdict(lambda: defaultdict(int))
    flags = defaultdict(set)
    for p in sorted(results.glob("*.csv")):
        bench = p.name.rsplit(".", 2)[0]
        info = p.with_suffix(".info")
        if info.exists() and not info.read_text().startswith("rc=0"):
            flags[bench].add("exit status not 0")
        ev = read_csv(p)
        for name in (CYC, INS):
            if name not in ev:
                flags[bench].add(f"{name} missing")
        for name, (count, pct) in ev.items():
            totals[bench][name] += count
            if pct < 99.9:
                flags[bench].add(f"{name} multiplexed ({pct:.0f} %)")
    return totals, flags


def per_k(ev, name, base=INS):
    return f"{1000 * ev.get(name, 0) / ev[base]:.2f}" if ev.get(base) and name in ev else "-"


def pct_of(ev, name, base):
    return f"{100 * ev[name] / ev[base]:.1f}" if ev.get(base) and name in ev else "-"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("results", type=Path)
    args = ap.parse_args()
    totals, flags = collect(args.results)
    cols = ["benchmark", "instr (M)", "cycles (M)", "CPI", "br/instr %", "mispred MPKI", "dir MPKI", "L1I MPKI", "L1D MPKI", "L1D miss %", "load stall %", "I$ stall %", "notes"]
    print("| " + " | ".join(cols) + " |")
    print("|" + "---|" * len(cols))
    for bench in sorted(totals):
        ev = totals[bench]
        if not ev.get(INS):
            print(f"| {bench} | no instructions counted |" + " |" * (len(cols) - 2))
            continue
        row = [
            bench,
            f"{ev[INS] / 1e6:.1f}",
            f"{ev.get(CYC, 0) / 1e6:.1f}",
            f"{ev[CYC] / ev[INS]:.2f}" if ev.get(CYC) else "-",
            pct_of(ev, BR, INS),
            per_k(ev, MISP),
            per_k(ev, DIRW),
            per_k(ev, L1I_M),
            per_k(ev, L1D_M),
            pct_of(ev, L1D_M, L1D_A),
            pct_of(ev, LD_STALL, CYC),
            pct_of(ev, IC_STALL, CYC),
            "; ".join(sorted(flags[bench])),
        ]
        print("| " + " | ".join(row) + " |")


if __name__ == "__main__":
    main()
