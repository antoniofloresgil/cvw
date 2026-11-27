#!/usr/bin/env python3
# Decode a CSV of the coherence controller's ILA (coherence-ila-capture.tcl) into one readable line per sample.
#   coherence-ila-decode.py capture.csv [--harts 2] [--from N] [--to N] [--flags]
import argparse
import csv

STATES = ["IDLE", "SNOOP", "WRITEBACK", "GRANT", "HELD", "?5", "?6", "?7"]
WSTATES = ["W_IDLE", "W_ADDR", "W_DATA", "?3"]
HTRANS = ["IDLE", "BUSY", "NSEQ", "SEQ"]
FLAGS = ["reissued-transfer-taken", "addr-changed-in-wait", "wdata-changed-in-wait", "HRESP",
         "writeback-readback-mismatch", "slot-stuck", "acquire-starved", "two-dirty-copies"]
HART_FIELDS = ["AcqReq", "AcqWrite", "AcqFlush", "Gnt", "GntExcl", "Rel", "SnpReq", "SnpInv", "SnpAck", "SnpHit", "SnpDirty", "FetchHold"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--harts", type=int, default=2)
    ap.add_argument("--from", dest="first", type=int, default=0)
    ap.add_argument("--to", type=int, default=1 << 30)
    ap.add_argument("--flags", action="store_true", help="only print the sticky flags of the first sample")
    a = ap.parse_args()
    rows = list(csv.reader(open(a.csv)))
    head = rows[0]
    col = {}
    for i, h in enumerate(head):
        name = h.split("/")[-1].split("[")[0]
        col[name] = i
    n = a.harts
    for r in rows[2:]:
        sample = int(r[col["Sample in Window"]])

        def v(k, r=r):
            return int(r[col[k]], 16)

        if a.flags:
            err = v("CohErr")
            print("sticky flags:", ", ".join(f for b, f in enumerate(FLAGS) if err >> b & 1) or "none")
            return
        if not a.first <= sample <= a.to:
            continue
        ctl, bus, harts = v("CohCtl"), v("CohBus"), v("CohHarts")
        state, wstate = STATES[ctl & 7], WSTATES[ctl >> 3 & 3]
        cw, cf, cfe = ctl >> 5 & 1, ctl >> 6 & 1, ctl >> 7 & 1
        nested, wbchk, hresp, hready = bus & 1, bus >> 1 & 1, bus >> 2 & 1, bus >> 3 & 1
        hburst, hsize, hwrite, htrans = bus >> 4 & 7, bus >> 7 & 7, bus >> 10 & 1, bus >> 11 & 3
        uphwrite, uphready, uphtrans = bus >> 13 & 1, bus >> 14 & 1, bus >> 15 & 3
        fields = {}
        for i, f in enumerate(reversed(HART_FIELDS)):
            fields[f] = harts >> (i * n) & ((1 << n) - 1)
        acq = v("CohAcqAdr")
        hs = " ".join(f"{f}={fields[f]:0{n}b}" for f in HART_FIELDS if fields[f])
        acqs = " ".join(f"A{h}={acq >> (32*h) & 0xffffffff:08x}" for h in range(n) if fields["AcqReq"] >> h & 1)
        line = (f"{sample:5d}{' T' if r[col['TRIGGER']] == '1' else '  '} {state:9s}{'(w)' if cw else ''}{'(f)' if cf else ''}{'(i)' if cfe else ''}"
                f"{'(n)' if nested else ''} cur={v('CohCur')} {v('CohCurAdr'):08x} {wstate:6s} | {hs} {acqs} | "
                f"up {HTRANS[uphtrans]}{' W' if uphwrite else ' R'}{' rdy' if uphready else ''} | "
                f"{HTRANS[htrans]} {v('CohHADDR'):08x}{' W' if hwrite else ' R'} s{hsize} b{hburst}{' RDY' if hready else ''}{' RESP' if hresp else ''}"
                f" wd={v('CohHWDATA'):016x} rd={v('CohHRDATA'):016x}{' wbchk' if wbchk else ''}")
        if v("CohErrNow"):
            line += "  <<< " + ", ".join(f for b, f in enumerate(FLAGS) if v("CohErrNow") >> b & 1)
        print(line)

main()
