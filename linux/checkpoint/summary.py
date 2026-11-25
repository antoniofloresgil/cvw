#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""One table for a whole campaign: SimPoint's weighted estimate of each benchmark against its whole region.

    summary.py <dir> <benchmark>... [--suffix -A] [--points '{b}{s}'] [--ref '{b}{s}-ref/0/wsim.log'] [--markdown]

Reads what measure.py and cluster.sh fetch leave next to the checkpoints, and runs nothing: for each benchmark the points
<dir>/<points>/<k>/ (hpm.txt, or the HPM lines of wsim.log) and the reference <dir>/<ref>, the log of the whole region
run from its start with +HPM_PERIOD=<interval>.  Per benchmark: how many points have a result and their share of
SimPoint's weight (the estimate uses the points there are, their weights scaled to 1), the CPI and the events per
thousand instructions weighted as SimPoint says, the same intervals measured in place in the reference (when it
covers them all: the checkpoints' own error), the whole region in the reference and how much of the region
(region_instructions in the reference's info.txt) it ran, and the estimate's CPI error against the region.  The last
line is the mean absolute CPI error over the benchmarks with every point and a whole reference (to the region's last
whole interval, where cluster.sh stops it).  In the templates {b}
is the benchmark and {s} the suffix; the local runs of the README use --points 'ckA-{b}' --ref 'refA-{b}/0/wsim.log'.
"""
import argparse
import pathlib
import sys

from measure import delta, hpm_lines, read_info

METRICS = [("cpi", "CPI"), ("ctl", "ctl MPKI"), ("dir", "dir MPKI"), ("d", "D MPKI"), ("i", "I MPKI")]


def rates(c):
    k = c["instret"] / 1000
    return {"cpi": c["cycles"] / c["instret"], "ctl": c["control_mispredicts"] / k, "dir": c["bp_dir_wrong"] / k,
            "d": c["dcache_miss"] / k, "i": c["icache_miss"] / k}


def point_counts(d, info):
    """The interval's counters of one point, or None if it has no result (yet)."""
    if (d / "hpm.txt").exists():
        return {k: int(v) for k, v in (line.split() for line in (d / "hpm.txt").read_text().splitlines())}
    log = d / "wsim.log"
    if not log.exists():
        return None
    lines = hpm_lines(log)
    warmup, end = info["warmup"], info["warmup"] + info["interval"]
    if end not in lines or (warmup and warmup not in lines):
        return None
    return delta(lines, warmup, end)


def weighted(pairs):
    """Weighted mean of rate dicts [(weight, rates)], weights scaled to their sum."""
    total = sum(w for w, _ in pairs)
    return {m: sum(w * r[m] for w, r in pairs) / total for m, _ in METRICS} if total else None


def bench(root, b, args):
    pdir = root / args.points.format(b=b, s=args.suffix)
    points = sorted((d for d in pdir.iterdir() if (d / "info.txt").exists()), key=lambda d: int(d.name)) \
        if pdir.is_dir() else []
    row = {"bench": b, "points": len(points), "done": 0, "weight": 0.0, "est": None, "inplace": None, "region": None,
           "covered": None, "complete": False, "err": None}
    if not points:
        return row
    ref_log = root / args.ref.format(b=b, s=args.suffix)
    ref = hpm_lines(ref_log) if ref_log.exists() else {}
    est, inplace, all_in_ref = [], [], True
    for d in points:
        info = read_info(d)
        c = point_counts(d, info)
        if c is None:
            continue
        w, interval, k = info["weight"], info["interval"], int(d.name)
        row["done"] += 1
        row["weight"] += w
        est.append((w, rates(c)))
        s, e = k * interval, (k + 1) * interval
        if e in ref and (s == 0 or s in ref):
            inplace.append((w, rates(delta(ref, s, e))))
        else:
            all_in_ref = False
    row["est"] = weighted(est)
    row["inplace"] = weighted(inplace) if all_in_ref and inplace else None
    if ref:
        last = max(ref)
        row["region"] = rates(delta(ref, 0, last))
        n = read_info(ref_log.parent).get("region_instructions") if (ref_log.parent / "info.txt").exists() else None
        row["covered"] = last / n if n else None
        interval = read_info(points[0])["interval"]
        row["complete"] = bool(n) and last >= n // interval * interval   # cluster.sh stops at the last whole interval
        row["ran"] = last
        if row["est"]:
            row["err"] = 100 * (row["est"]["cpi"] / row["region"]["cpi"] - 1)
    return row


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir", type=pathlib.Path)
    ap.add_argument("benchmarks", nargs="+")
    ap.add_argument("--suffix", default="-A")
    ap.add_argument("--points", default="{b}{s}", help="points directory under <dir> ('{b}{s}')")
    ap.add_argument("--ref", default="{b}{s}-ref/0/wsim.log", help="reference log under <dir> ('{b}{s}-ref/0/wsim.log')")
    ap.add_argument("--markdown", action="store_true", help="a Markdown table (for the README)")
    args = ap.parse_args()
    rows = [bench(args.dir, b, args) for b in args.benchmarks]

    def f(r, m, fmt="{:.3f}"):
        return fmt.format(r[m]) if r else "-"

    cols = ["benchmark", "points", "weight"] + [f"{t} est/region" for _, t in METRICS] + ["CPI in place", "region run",
                                                                                         "CPI error"]
    table = []
    for r in rows:
        cov = (f"{r['covered']:.0%}" if r["covered"] is not None else f"{r['ran'] / 1e6:.0f} M") if r["region"] else "-"
        table.append([r["bench"], f"{r['done']}/{r['points']}", f"{r['weight']:.2f}"]
                     + [f"{f(r['est'], m)} / {f(r['region'], m)}" for m, _ in METRICS]
                     + [f(r["inplace"], "cpi"), cov, f"{r['err']:+.1f} %" if r["err"] is not None else "-"])
    full = [r for r in rows if r["err"] is not None and r["done"] == r["points"] and r["complete"]]
    if args.markdown:
        print("| " + " | ".join(cols) + " |")
        print("|" + "---|" * len(cols))
        for t in table:
            print("| " + " | ".join(t) + " |")
    else:
        widths = [max(len(c), *(len(t[i]) for t in table)) for i, c in enumerate(cols)]
        print("  ".join(c.rjust(w) for c, w in zip(cols, widths)))
        for t in table:
            print("  ".join(x.rjust(w) for x, w in zip(t, widths)))
    if full:
        print(f"\nmean |CPI error| over {len(full)} benchmark(s) with every point and the whole region: "
              f"{sum(abs(r['err']) for r in full) / len(full):.1f} %")
    pending = [r["bench"] for r in rows if r["done"] < r["points"] or not r["region"]]
    if pending:
        print(f"incomplete (points or reference missing): {' '.join(pending)}", file=sys.stderr)


if __name__ == "__main__":
    main()
