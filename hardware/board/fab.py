#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Manufacturing files for JLCPCB from the routed board, all with kicad-cli, into fab/ (git-ignored,
build products):
  fab/gerber/ and fab/mcu_board-gerber.zip   Gerbers of the four copper layers, masks, paste,
                                             silkscreen and outline, and the Excellon drill files
  fab/mcu_board-bom.csv                      bill of materials in JLCPCB's columns (Comment,
                                             Designator, Footprint, LCSC left empty: JLCPCB's tool
                                             matches by value and footprint and prefers its basic parts)
  fab/mcu_board-cpl.csv                      placement in JLCPCB's columns (Designator, Mid X, Mid Y,
                                             Layer, Rotation); check the rotations in JLCPCB's preview
  fab/mcu_board-schematic.pdf, fab/mcu_board-pcb.pdf
Parts that are not assembled: U6 (the chip goes in a QFN socket soldered by hand), the test points,
the mounting holes.  Run after mcu_pcb.py and route.py:  python3 fab.py
"""

import csv
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FAB = HERE / "fab"
PCB = HERE / "mcu_board.kicad_pcb"
SCH = HERE / "mcu_board.kicad_sch"
NOT_ASSEMBLED = ("U6",)                      # plus every TP and H
LAYERS = ["F.Cu", "In1.Cu", "In2.Cu", "B.Cu", "F.Paste", "B.Paste", "F.Silkscreen", "B.Silkscreen",
          "F.Mask", "B.Mask", "Edge.Cuts"]


def cli(*args):
    subprocess.run(["kicad-cli", *map(str, args)], check=True, capture_output=True)


def natural(ref):
    """Sort key: R2 before R10."""
    prefix = ref.rstrip("0123456789")
    return prefix, int(ref[len(prefix):] or 0)


def assembled(ref):
    return ref not in NOT_ASSEMBLED and not ref.startswith(("TP", "H", "#"))


def main():
    gerber = FAB / "gerber"
    gerber.mkdir(parents=True, exist_ok=True)
    for old in gerber.iterdir():
        old.unlink()
    cli("pcb", "export", "gerbers", "--layers", ",".join(LAYERS), "--subtract-soldermask", "-o", f"{gerber}/", PCB)
    cli("pcb", "export", "drill", "--format", "excellon", "--excellon-units", "mm", "--generate-map",
        "--map-format", "gerberx2", "-o", f"{gerber}/", PCB)
    with zipfile.ZipFile(FAB / "mcu_board-gerber.zip", "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(gerber.iterdir()):
            z.write(f, f.name)

    # bill of materials, from the schematic's netlist: one line per value and footprint
    with tempfile.TemporaryDirectory() as tmp:
        net = Path(tmp) / "net.xml"
        cli("sch", "export", "netlist", "--format", "kicadxml", "-o", net, SCH)
        comps = ET.parse(net).getroot().iter("comp")
        groups = {}
        for c in comps:
            ref = c.get("ref")
            if assembled(ref):
                key = (c.findtext("value"), c.findtext("footprint").split(":")[1])
                groups.setdefault(key, []).append(ref)
    with open(FAB / "mcu_board-bom.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Comment", "Designator", "Footprint", "LCSC Part #"])
        for (value, fp), refs in sorted(groups.items(), key=lambda kv: natural(sorted(kv[1], key=natural)[0])):
            w.writerow([value, ",".join(sorted(refs, key=natural)), fp, ""])

    # placement
    with tempfile.TemporaryDirectory() as tmp:
        pos = Path(tmp) / "pos.csv"
        cli("pcb", "export", "pos", "--format", "csv", "--units", "mm", "--side", "both",
            "-o", pos, PCB)
        rows = list(csv.DictReader(open(pos)))
    with open(FAB / "mcu_board-cpl.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Designator", "Mid X", "Mid Y", "Layer", "Rotation"])
        for r in rows:
            if assembled(r["Ref"]):
                w.writerow([r["Ref"], f'{float(r["PosX"]):.3f}mm', f'{float(r["PosY"]):.3f}mm',
                            "Top" if r["Side"] == "top" else "Bottom", f'{float(r["Rot"]):.0f}'])

    cli("sch", "export", "pdf", "-o", FAB / "mcu_board-schematic.pdf", SCH)
    cli("pcb", "export", "pdf", "--layers", "F.Cu,In1.Cu,In2.Cu,B.Cu,F.Silkscreen,F.Fab",
        "--common-layers", "Edge.Cuts", "--mode-multipage", "-o", FAB / "mcu_board-pcb.pdf", PCB)
    parts = sum(len(v) for v in groups.values())
    print(f"{FAB}: gerbers ({len(list(gerber.iterdir()))} files, zipped), BOM {len(groups)} lines / {parts} parts, "
          f"CPL {parts} placements, schematic and PCB PDFs")


if __name__ == "__main__":
    main()
