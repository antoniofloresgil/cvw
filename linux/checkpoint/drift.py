#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Where Wally and QEMU part after the same checkpoint.

    drift.py <qemu trace> <wally trace> [--context N] [--show N]

The traces: QEMU's from checkpoint.sh with TRACE=<n> (roickpt), Wally's from the testbench's +PC_TRACE=<file>: one hex
PC per executed instruction and "T I <pc>" / "T E <pc>" at each interrupt / exception.  QEMU's plugin also sees an
instruction that traps (its callback runs before the instruction), so a PC followed by "T E" of the same PC is dropped:
what is left is what minstret counts on Wally.  The two are walked together; where they differ, the walk looks ahead
for the next point where a run of PCs agrees again (an interrupt taken at another instruction, a different number of
iterations of a polling loop, ...) and reports each such divergence: where, how many instructions each side ran
before they agree again, and the traps in between.  Standard library only.
"""
import argparse
import sys


def load(path):
    """Lists of PCs (int) and, per index, the traps taken just before that instruction."""
    pcs, traps = [], {}
    with open(path) as f:
        for line in f:
            if line[0] == "T":
                _, kind, pc = line.split()
                pc = int(pc, 16)
                if kind == "E" and pcs and pcs[-1] == pc and len(pcs) not in traps:
                    pcs.pop()          # QEMU: the faulting instruction did not retire
                traps.setdefault(len(pcs), []).append((kind, pc))
            else:
                pcs.append(int(line, 16))
    return pcs, traps


def resync(a, i, b, j, run, window):
    """Smallest (di + dj) such that a[i+di : i+di+run] == b[j+dj : j+dj+run], searched within window; None if none."""
    # index the next window of b by PC to find candidate positions quickly
    pos = {}
    for k in range(j, min(len(b) - run, j + window)):
        pos.setdefault(b[k], []).append(k)
    best = None
    for di in range(0, min(len(a) - run - i, window)):
        if best is not None and di >= best[0] + best[1]:
            break
        for k in pos.get(a[i + di], ()):
            if best is not None and di + (k - j) >= best[0] + best[1]:
                break
            if a[i + di:i + di + run] == b[k:k + run]:
                best = (di, k - j)
                break
    return best


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("qemu")
    ap.add_argument("wally")
    ap.add_argument("--run", type=int, default=64, help="PCs that must agree to count as back in step (64)")
    ap.add_argument("--window", type=int, default=200000, help="how far to look ahead to get back in step (200000)")
    ap.add_argument("--show", type=int, default=20, help="divergences to list (20)")
    args = ap.parse_args()
    q, qt = load(args.qemu)
    w, wt = load(args.wally)
    print(f"QEMU: {len(q)} instructions, {sum(len(v) for v in qt.values())} traps "
          f"({sum(1 for v in qt.values() for t in v if t[0] == 'I')} interrupts); "
          f"Wally: {len(w)} instructions, {sum(len(v) for v in wt.values())} traps "
          f"({sum(1 for v in wt.values() for t in v if t[0] == 'I')} interrupts)")

    def traps_in(tr, lo, hi):
        return [f"{k}:{pc:x}" for x in range(lo, hi + 1) for k, pc in tr.get(x, ())]

    i = j = 0
    divs = []
    while i < len(q) and j < len(w):
        if q[i] == w[j] and qt.get(i) == wt.get(j):
            i += 1; j += 1
            continue
        if q[i] == w[j]:   # same instruction, but a trap before it on one side only: count it, go on
            divs.append((i, j, 0, 0, traps_in(qt, i, i), traps_in(wt, j, j), q[i], w[j]))
            i += 1; j += 1
            continue
        r = resync(q, i, w, j, args.run, args.window)
        if r is None:
            divs.append((i, j, None, None, traps_in(qt, i, i), traps_in(wt, j, j), q[i], w[j]))
            break
        di, dj = r
        divs.append((i, j, di, dj, traps_in(qt, i, i + di), traps_in(wt, j, j + dj), q[i], w[j]))
        i += di; j += dj

    print(f"{len(divs)} divergences; the first at instruction {divs[0][0] if divs else '-'} of QEMU's trace")
    print(f"{'qemu idx':>10} {'wally idx':>10} {'qemu pc':>18} {'wally pc':>18} {'+qemu':>7} {'+wally':>7}  traps (qemu | wally)")
    for d in divs[:args.show]:
        i, j, di, dj, tq, tw, pq, pw = d
        print(f"{i:>10} {j:>10} {pq:>18x} {pw:>18x} {di!s:>7} {dj!s:>7}  {' '.join(tq) or '-'} | {' '.join(tw) or '-'}")
    if divs and divs[-1][2] is None:
        print(f"lost step at QEMU {divs[-1][0]}, Wally {divs[-1][1]}: no common run of {args.run} PCs within {args.window}")
    else:
        print(f"in step to the end: QEMU at {i} of {len(q)}, Wally at {j} of {len(w)} "
              f"(Wally ran {j - i:+d} instructions relative to QEMU)")
    extra = sum((d[3] or 0) - (d[2] or 0) for d in divs)
    print(f"instructions only one side ran, net: {extra:+d} (Wally minus QEMU)")


if __name__ == "__main__":
    sys.exit(main())
