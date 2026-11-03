#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Check the Magic DRC of a LibreLane run that uses IHP SRAM macros.

With the SRAM rule exceptions of IHP-Open-PDK PR #863 (and the subcells that
libs.tech/magic/read_sram_gds.tcl flattens, MAGIC_GDS_FLATGLOB), Magic still reports Cnt.c
violations inside the SRAM macros themselves: "Cnt.c" in their periphery and "Cnt.c SRAM
exception" in their array.  Magic's author considers them errors in IHP's layout (issue #794);
the KLayout deck accepts them (issue #1024).  A run with macros therefore sets
ERROR_ON_MAGIC_DRC to false, and this script fails instead on any Magic violation that is not
one of those rules inside the bounding box of a macro instance.  KLayout DRC stays fatal.

In a chip, Magic also reports overlaps between the subcells of IHP's pad ring (the pad, corner
and filler cells abut with shapes that Magic's hierarchical check does not accept).  The
official checker of the PDK, KLayout's DRC deck, finds no error there, and IHP's LibreLane
template removes Checker.IllegalOverlap for them; this script turns those rules outside the
core area into warnings when KLayout DRC is clean.
"""

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

# Magic rules violated inside the IHP SRAM macros; remove when IHP fixes the macros
MACRO_RULES = {"Cnt.c", "Cnt.c SRAM exception"}
# Magic rules violated where the cells of the pad ring overlap; these have no rule name
PAD_RING_RULES = {"Can't overlap those layers", "This layer can't abut or partially overlap between subcells"}

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("run", type=Path, nargs="?", help="Run directory (default: the newest in runs/)")
args = parser.parse_args()

run = (args.run or max(Path("runs").iterdir(), key=lambda d: d.stat().st_mtime)).resolve()
resolved = json.loads((run / "resolved.json").read_text())
design = resolved["DESIGN_NAME"]

# Bounding box of every macro instance, in um, from the final DEF and the macros' LEF sizes
sizes = {}
for name, macro in resolved["MACROS"].items():
    w, h = map(float, re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", Path(macro["lef"][0]).read_text()).groups())
    sizes[name] = (w, h)
deftext = (run / "final/def" / f"{design}.def").read_text()
dbu = int(re.search(r"UNITS DISTANCE MICRONS (\d+)", deftext).group(1))
boxes = []
for name, x, y, orient in re.findall(r"^\s*- \S+ (\S+) \+ (?:FIXED|PLACED) \( (-?\d+) (-?\d+) \) (\S+)", deftext, re.M):
    if name in sizes:
        w, h = sizes[name] if orient in ("N", "S", "FN", "FS") else sizes[name][::-1]
        boxes.append((int(x) / dbu, int(y) / dbu, int(x) / dbu + w, int(y) / dbu + h))
if len(boxes) != sum(len(m["instances"]) for m in resolved["MACROS"].values()):
    sys.exit(f"found {len(boxes)} macro instances in the DEF, expected one per instance in MACROS")

# The pad ring is everything outside the core area of a chip (a design with pads)
core = resolved["CORE_AREA"] if any(resolved.get(f"PAD_{s}") for s in ("SOUTH", "EAST", "NORTH", "WEST")) else None
klayout_errors = json.loads((run / "final/metrics.json").read_text())["klayout__drc_error__count"]

report = next(run.glob("*-magic-drc/reports/drc.magic.rpt"))
waived, padring, other, rule = Counter(), Counter(), Counter(), None
for line in report.read_text().splitlines()[1:]:
    coords = re.findall(r"(-?[\d.]+)um", line)
    if len(coords) == 4:
        x0, y0, x1, y1 = map(float, coords)
        inside = any(bx0 <= x0 and x1 <= bx1 and by0 <= y0 and y1 <= by1 for bx0, by0, bx1, by1 in boxes)
        in_ring = core is not None and not (core[0] <= x0 and x1 <= core[2] and core[1] <= y0 and y1 <= core[3])
        if inside and rule in MACRO_RULES:
            waived[rule] += 1
        elif in_ring and rule in PAD_RING_RULES and klayout_errors == 0:
            padring[rule] += 1
        else:
            other[rule] += 1
    elif line.strip() and not line.startswith(("---", "[INFO]")):
        named = re.search(r"\(([^()]*)\)\s*$", line)       # the rule name ends the description, if any
        rule = named.group(1) if named else line.strip()

print(f"Magic DRC ({report}): {sum(waived.values())} violations inside {len(boxes)} SRAM macro instance(s), "
      f"{sum(other.values())} other")
for r, n in sorted(waived.items()):
    print(f"  {r}: {n}")
for r, n in sorted(padring.items()):
    print(f"  WARNING {r}: {n} in the pad ring, where KLayout DRC (the PDK's official deck) finds 0 errors")
for r, n in sorted(other.items()):
    print(f"  NOT WAIVED {r}: {n}")
print("DRC FAILED" if other else "DRC OK")
sys.exit(bool(other))
