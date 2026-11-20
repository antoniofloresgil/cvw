#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Run the checkpoints of checkpoint.sh on Wally and weight their HPM counts as SimPoint says.

  measure.py <checkpoint dir> [--jobs N] [--sim verilator] [--reference <wsim log>]

Each <checkpoint dir>/<k>/ (with ram.bin, bootmem.bin, info.txt) runs as
  wsim buildroot buildroot --args "+LinuxRam=... +LinuxBootmem=... +INSTR_LIMIT=<warm-up + interval> +HPM_WARMUP=<warm-up>"
and the testbench prints the counters ("HPM <minstret> <counter 0> ...") at the end of the warm-up and of the interval;
the difference is the interval's count (<k>/hpm.txt, <k>/wsim.log; a point already measured is not run again).  The
result is each interval's CPI and events per thousand instructions, and their sums weighted by SimPoint's weights
(the intervals are equally long, so the weighted CPI estimates the region's).  --reference takes the log of a run of
the whole region from its start with +HPM_PERIOD=<interval> and compares each point with that interval measured in place.
"""
import argparse
import concurrent.futures
import pathlib
import subprocess
import sys

# Wally's counters (src/privileged/pmuevents.sv; keep in step with it and linux/pmu/events.py)
NAMES = {0: "cycles", 2: "instret", 3: "branches", 4: "jumps", 5: "returns", 6: "bp_wrong", 7: "bp_dir_wrong",
         8: "bta_wrong", 9: "ras_wrong", 10: "iclass_wrong", 11: "load_stall", 12: "store_stall", 13: "dcache_access",
         14: "dcache_miss", 15: "dcache_stall_cycles", 16: "icache_access", 17: "icache_miss",
         18: "icache_stall_cycles", 19: "csr_write", 20: "fencei", 21: "sfence_vma", 22: "interrupts",
         23: "exceptions", 24: "divide_cycles", 25: "control_transfers", 26: "control_mispredicts"}
SHOWN = ["bp_wrong", "dcache_miss", "icache_miss", "load_stall", "interrupts", "exceptions"]


def read_info(d):
    info = {}
    for line in (d / "info.txt").read_text().splitlines():
        key, value = line.split()
        info[key] = float(value) if key == "weight" else int(value)
    return info


def hpm_lines(log):
    """{minstret: [counters]} from the testbench's HPM lines"""
    lines = {}
    for line in log.read_text(errors="replace").splitlines():
        if line.startswith("HPM "):
            fields = [int(f) for f in line.split()[1:]]
            lines.setdefault(fields[0], fields[1:])
    return lines


def delta(lines, start, end):
    first = lines[start] if start else [0] * len(lines[end])
    return {NAMES[c]: lines[end][c] - first[c] for c in NAMES if c < len(lines[end])}


def run(d, sim):
    info = read_info(d)
    warmup, interval = info["warmup"], info["interval"]
    log = d / "wsim.log"
    have = log.exists() and warmup + interval in hpm_lines(log)  # e.g. a log fetched from the cluster (cluster.sh)
    if not (d / "hpm.txt").exists() and not have:
        args = (f"+LinuxRam={d / 'ram.bin'} +LinuxBootmem={d / 'bootmem.bin'} +INSTR_LIMIT={warmup + interval} "
                f"+UART_LOG_FILE={d / 'uart.out'}" + (f" +HPM_WARMUP={warmup}" if warmup else ""))
        with log.open("w") as f:
            subprocess.run(["wsim", "buildroot", "buildroot", "--sim", sim, "--args", args], stdout=f,
                           stderr=subprocess.STDOUT, check=False)
    if not (d / "hpm.txt").exists():
        lines = hpm_lines(log)
        if warmup + interval not in lines or (warmup and warmup not in lines):
            raise RuntimeError(f"{d}: no HPM line at {warmup + interval} (see {log})")
        counts = delta(lines, warmup, warmup + interval)
        (d / "hpm.txt").write_text("".join(f"{name} {value}\n" for name, value in counts.items()))
    counts = {k: int(v) for k, v in (line.split() for line in (d / "hpm.txt").read_text().splitlines())}
    return int(d.name), info, counts


def rates(c):
    r = {"cpi": c["cycles"] / c["instret"]}
    r.update({name: 1000 * c[name] / c["instret"] for name in SHOWN})
    return r


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir", type=pathlib.Path)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--sim", default="verilator")
    ap.add_argument("--reference", type=pathlib.Path)
    args = ap.parse_args()
    points = sorted((d for d in args.dir.resolve().iterdir() if (d / "info.txt").exists()), key=lambda d: int(d.name))
    if not points:
        sys.exit(f"no checkpoints in {args.dir}")
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        results = list(pool.map(lambda d: run(d, args.sim), points))

    ref = hpm_lines(args.reference) if args.reference else None
    header = f"{'interval':>8} {'weight':>6} {'cpi':>7} " + " ".join(f"{n:>12}" for n in SHOWN)
    print("per thousand instructions after the CPI" + (" (reference below each point)" if ref else ""))
    print(header)
    weighted = {}
    weighted_ref = {}
    missing = []  # points that the reference does not cover
    total = 0.0
    for k, info, counts in results:
        w = info.get("weight", 0.0)
        r = rates(counts)
        total += w
        for key, value in r.items():
            weighted[key] = weighted.get(key, 0.0) + w * value
        print(f"{k:>8} {w:>6.3f} {r['cpi']:>7.3f} " + " ".join(f"{r[n]:>12.3f}" for n in SHOWN))
        if ref is not None:
            interval = info["interval"]
            start, end = k * interval, (k + 1) * interval
            if end in ref and (start == 0 or start in ref):
                rr = rates(delta(ref, start, end))
                for key, value in rr.items():
                    weighted_ref[key] = weighted_ref.get(key, 0.0) + w * value
                print(f"{'ref':>8} {'':>6} {rr['cpi']:>7.3f} " + " ".join(f"{rr[n]:>12.3f}" for n in SHOWN))
            else:
                missing.append(k)
    if total:
        print(f"{'weighted':>8} {total:>6.3f} {weighted['cpi'] / total:>7.3f} "
              + " ".join(f"{weighted[n] / total:>12.3f}" for n in SHOWN))
        if weighted_ref and not missing:
            print(f"{'ref':>8} {'':>6} {weighted_ref['cpi'] / total:>7.3f} "
                  + " ".join(f"{weighted_ref[n] / total:>12.3f}" for n in SHOWN))
    if missing:
        print(f"the reference does not cover interval(s) {' '.join(map(str, missing))}: no weighted reference")
    if ref is not None:
        last = max(ref)
        whole = rates(delta(ref, 0, last))
        print(f"{'region':>8} {'':>6} {whole['cpi']:>7.3f} " + " ".join(f"{whole[n]:>12.3f}" for n in SHOWN)
              + f"   (the whole region in the reference, {last} instructions)")


if __name__ == "__main__":
    main()
