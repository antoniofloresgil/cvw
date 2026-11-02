#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Check the KLayout DRC of a LibreLane run that uses IHP SRAM macros.

The full IHP deck reports violations of three rules inside the SRAM macros themselves
(IHP-Open-PDK issue #793): Cnt.c.digibnd in the array, Sdiod.d and Sdiod.e in the periphery,
where the deck takes elongated contacts in wide N-wells for Schottky diodes.  A run with
macros therefore sets ERROR_ON_KLAYOUT_DRC to false, and this script fails instead when
  1. the full deck reports any violation that is not one of those rules inside a macro cell, or
  2. IHP's foundry precheck rule set (precheck_drc=true), run here on the final GDS, reports any.
Run it inside LibreLane's Nix environment (it needs klayout).
"""

import argparse
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

# Rules the full deck reports inside the IHP SRAM macros; remove when #793 is fixed
MACRO_RULES = {"Cnt.c.digibnd", "Sdiod.d", "Sdiod.e"}
# Cells of the SRAM macros (RM_*) and of their own standard cells (RSC_*); Magic's streamout adds a
# two-letter prefix that changes from run to run (LV_, FQ_, ...)
MACRO_CELL = re.compile(r"([A-Z]{2}_)?(RM|RSC)_IHPSG13_")

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("run", type=Path, nargs="?", help="Run directory (default: the newest in runs/)")
parser.add_argument("--threads", type=int, default=8, help="KLayout threads for the precheck")
args = parser.parse_args()

run = (args.run or max(Path("runs").iterdir(), key=lambda d: d.stat().st_mtime)).resolve()
resolved = json.loads((run / "resolved.json").read_text())
design = resolved["DESIGN_NAME"]


def items(lyrdb):
    """(rule, cell) of every violation in a KLayout report database"""
    for item in ET.parse(lyrdb).getroot().find("items"):
        yield item.findtext("category").strip("'"), item.findtext("cell").split(":")[0]


failed = False

lyrdb = next(run.glob("*-klayout-drc/reports/drc.klayout.lyrdb"))
waived, other = Counter(), Counter()
for rule, cell in items(lyrdb):
    (waived if rule in MACRO_RULES and MACRO_CELL.match(cell) else other)[rule, cell] += 1
print(f"Full deck ({lyrdb}): {sum(waived.values())} violations in IHP SRAM macro cells "
      f"(IHP-Open-PDK #793), {sum(other.values())} other")
for rule in sorted(MACRO_RULES):
    print(f"  {rule}: {sum(n for (r, _), n in waived.items() if r == rule)}")
for (rule, cell), n in sorted(other.items()):
    print(f"  NOT WAIVED {rule} in {cell}: {n}")
failed |= bool(other)

gds = run / "final/gds" / f"{design}.gds"
report = run / "precheck-drc.lyrdb"
subprocess.run(["klayout", "-b", "-zz", "-r", resolved["KLAYOUT_DRC_RUNSET"],
                "-rd", f"input={gds}", "-rd", f"topcell={design}", "-rd", f"report={report}",
                "-rd", "precheck_drc=true", "-rd", "no_recommended=true", "-rd", "run_mode=deep",
                "-rd", f"thr={args.threads}"],
               check=True, stdout=subprocess.DEVNULL)
precheck = Counter(rule for rule, _ in items(report))
print(f"IHP precheck rule set ({report}): {sum(precheck.values())} violations")
for rule, n in sorted(precheck.items()):
    print(f"  {rule}: {n}")
failed |= bool(precheck)

print("DRC FAILED" if failed else "DRC OK")
sys.exit(failed)
