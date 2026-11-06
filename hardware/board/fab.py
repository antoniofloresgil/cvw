#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Manufacturing files for JLCPCB from the routed board, all with kicad-cli, into fab/ (git-ignored,
build products):
  fab/gerber/ and fab/mcu_board-gerber.zip   Gerbers of the four copper layers, masks, paste,
                                             silkscreen and outline, and the Excellon drill files
  fab/mcu_board-bom.csv                      bill of materials in JLCPCB's columns (Comment,
                                             Designator, Footprint, LCSC Part #); LCSC numbers from
                                             LCSC below, checked against JLCPCB's catalogue (2026-11-06);
                                             through-hole headers and jumpers are left empty, to be
                                             soldered by hand
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

# LCSC part per (value, footprint).  JLCPCB basic parts (no loading fee) where one exists: the
# resistors, capacitors and FB1; the rest are extended parts.
LCSC = {
    ("10u", "C_0805_2012Metric"): "C15850",                 # CL21A106KAYNNNE, basic
    ("100n", "C_0603_1608Metric"): "C14663",                # CC0603KRX7R9BB104, basic
    ("18p", "C_0603_1608Metric"): "C1647",                  # CL10C180JB8NNNC C0G, basic
    ("4.7u", "C_0805_2012Metric"): "C1779",                 # CL21A475KAQNNNE, basic
    ("green", "LED_0603_1608Metric"): "C12624",             # KT-0603G (no basic green 0603 in stock)
    ("500mA", "Fuse_1206_3216Metric"): "C69688",            # nSMD050 polyfuse, 500 mA hold, 6 V
    ("600R@100MHz", "L_0603_1608Metric"): "C1002",          # GZ1608D601TF, 200 mA, basic
    ("USB-C", "USB_C_Receptacle_HRO_TYPE-C-31-M-12"): "C165948",
    ("Pin header 2x05 1.27mm (Cortex JTAG)", "PinHeader_2x05_P1.27mm_Vertical_SMD"): "C5155080",  # FTSH-105-01-L-DV-K
    ("5.1k", "R_0603_1608Metric"): "C23186",                # basic
    ("2.2k", "R_0603_1608Metric"): "C4190",                 # basic
    ("1k", "R_0603_1608Metric"): "C21190",                  # basic
    ("12k 1%", "R_0603_1608Metric"): "C22790",              # basic
    ("10k", "R_0603_1608Metric"): "C25804",                 # basic
    ("33", "R_0603_1608Metric"): "C23140",                  # basic
    ("4.7k", "R_0603_1608Metric"): "C23162",                # basic
    ("47k", "R_0603_1608Metric"): "C25819",                 # basic
    ("10k", "Potentiometer_Bourns_3314J_Vertical"): "C36376",  # 3314J-1-103E
    ("TL3342", "SW_SPST_TL3342"): "C2886897",               # TL3342F450QG
    ("DIP switch 6x slide", "SW_DIP_SPSTx06_Slide_6.7x16.8mm_W8.61mm_P2.54mm_LowProfile"): "C2842672",  # CTS 219-6MST, the footprint's land pattern; low stock (20 on 2026-11-06)
    ("USBLC6-2SC6", "SOT-23-6"): "C7519",
    ("AP2112K-3.3", "SOT-23-5"): "C51118",                  # AP2112K-3.3TRG1
    ("AP2112K-1.2", "SOT-23-5"): "C460310",                 # AP2112K-1.2TRG1
    ("FT2232HL", "LQFP-64_10x10mm_P0.5mm"): "C27882",       # FT2232HL-REEL
    ("93LC56B", "SOIC-8_3.9x4.9mm_P1.27mm"): "C183620",     # 93LC56B-I/SN
    ("MAX811SEUS-T", "SOT-143"): "C33724",                  # MAX811SEUS+T
    ("W25Q32JVSS", "SOIC-8_5.3x5.3mm_P1.27mm"): "C179173",  # W25Q32JVSSIQ
    ("74AHC541", "TSSOP-20_4.4x6.5mm_P0.65mm"): "C406865",  # SN74AHC541PWR
    ("24LC256", "SOIC-8_3.9x4.9mm_P1.27mm"): "C5458",       # 24LC256T-I/SN
    ("TMP102", "SOT-563"): "C99269",                        # TMP102AIDRLR
    ("ADS1115", "TSSOP-10_3x3mm_P0.5mm"): "C37593",         # ADS1115IDGSR
    ("MCP4725", "SOT-23-6"): "C144198",                     # MCP4725A0T-E/CH
    ("18.432MHz", "Oscillator_SMD_Abracon_ASE-4Pin_3.2x2.5mm"): "C2831385",  # OT322518.432MJBA4SL, CMOS
    ("12MHz", "Crystal_SMD_3225-4Pin_3.2x2.5mm"): "C70565",  # X322512MOB4SI, 12 pF load (C7, C8 18 pF)
}
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
            w.writerow([value, ",".join(sorted(refs, key=natural)), fp, LCSC.get((value, fp), "")])

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
