#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Places the test board's PCB from the schematic: reads the netlist (kicad-cli), loads every
footprint from KiCad's libraries, gives each pad its net and places the parts by function on a
110 x 85 mm four-layer board (In1 GND, In2 +3V3): the connectors on the edges (USB-C and the UART on
the left, the Pmod headers on top, the analog header on the right), each IC with its passives beside
it, and a row along the bottom edge with a test point, an LED and a button for each GPIO.  Run with the Python that has KiCad's pcbnew
module (the system Python):  python3 mcu_pcb.py   -> mcu_board.kicad_pcb, unrouted.
"""

import json
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

import pcbnew

HERE = Path(__file__).resolve().parent
FPDIR = Path("/usr/share/kicad/footprints")
W, H = 110.0, 85.0                      # board, mm
ORIGIN = (100.0, 60.0)                  # the board's top left corner on the page
GAP = 0.8                               # between courtyards

# Placement by function.  FIXED parts sit at (x, y, rotation) on the board (mm from its top left
# corner); each GROUP is packed, in the order given, into its rectangle (x0, y0, x1, y1) beside the
# part it serves.  Every footprint must be in exactly one of them.
FIXED = {
    "J1": (5.0, 19.0, 270),                                   # USB-C, left edge
    # Pmod headers, right angle: pin 1 6.6 mm in, so the plastic ends at the edge and the pins stick out
    "J5": (48.0, 6.6, 90), "J6": (66.0, 6.6, 90), "J7": (84.0, 6.6, 90),
    "H1": (3.5, 3.5, 0), "H2": (W - 3.5, 3.5, 0), "H3": (3.5, H - 3.5, 0), "H4": (W - 3.5, H - 3.5, 0),
    "U4": (24.0, 47.0, 0),                                    # FT2232HL
    "J3": (3.5, 57.0, 0),                                     # UART header, left edge beside the FT2232HL
    "J2": (41.0, 30.0, 0),                                    # JTAG header beside the chip
    "U6": (57.0, 33.0, 0),                                    # the chip
    "X1": (49.0, 42.0, 0),                                    # oscillator by the clock pin
    "U8": (72.0, 30.0, 0),                                    # SPI flash by the SPI pins
    "SW1": (12.0, 77.0, 0),                                   # RESET, apart from the GPIO buttons
    "SW2": (97.0, 52.0, 90),                                  # boot straps
    "J4": (106.0, 22.0, 0),                                   # analog header, right edge
}
# The GPIO row along the bottom edge: test point, LED resistor, LED, button resistor, button per GPIO
ROW_X = [44 + 9.5 * i for i in range(6)] + [101.0, 106.0]
for i, x in enumerate(ROW_X):
    FIXED[f"TP{20 + i}"] = (x, 63.0, 0)
    FIXED[f"R{38 + i}"] = (x, 66.5, 90)
    FIXED[f"D{3 + i}"] = (x, 70.0, 90)
    if i < 6:
        FIXED[f"R{32 + i}"] = (x, 73.5, 0)
        FIXED[f"SW{3 + i}"] = (x, 78.0, 0)


def refs(spec):
    """'R9-R15 C7' -> ['R9', ..., 'R15', 'C7']"""
    out = []
    for item in spec.split():
        if "-" in item:
            a, b = item.split("-")
            prefix = a.rstrip("0123456789")
            out += [f"{prefix}{n}" for n in range(int(a[len(prefix):]), int(b.lstrip(prefix)) + 1)]
        else:
            out.append(item)
    return out


GROUPS = [
    ("U1 F1 R1 R2 U2 C1-C4 U3 C5 C6 JP1 JP2 R3 D1 R4 D2 TP1-TP7", (12, 9, 37, 34)),    # power
    ("Y1 C7 C8", (8, 38, 16.5, 52)),                                                 # FT2232HL crystal
    ("R9-R15", (32, 38, 40, 54)),                                                    # FT2232HL to the chip
    ("C9-C19 FB1 R5 R6 U5 R7 R8", (10, 55, 40, 68)),                                 # FT2232HL supply, EEPROM
    ("C21-C23 C31-C33", (50, 21, 66, 29.5)),                                         # chip decoupling
    ("C40 R16 U7", (52, 38, 66, 45)),                                                # clock and reset
    ("TP10-TP15", (42, 46, 66, 51)),
    ("C41 R17-R19", (66, 36, 80, 42)),                                               # flash
    ("U9 C42", (42, 52, 58, 61)),                                                    # LED buffer
    ("R20-R31", (74, 44, 87.5, 61)),                                                 # strap resistors
    ("U10 U11 U12 U13 RV1 C43-C46 R46 R47", (78, 12, 103, 40)),                      # I2C and analog
]
RULES = {   # mm; the default net class and the board's minimums, written into mcu_board.kicad_pro
    "clearance": 0.15, "track_width": 0.2, "via_diameter": 0.6, "via_drill": 0.3,
    "min_clearance": 0.15, "min_track_width": 0.15, "min_via_diameter": 0.5, "min_through_hole_diameter": 0.3,
    "min_copper_edge_clearance": 0.3,
}


def mm(v):
    return pcbnew.FromMM(v)


def at(x, y):
    return pcbnew.VECTOR2I(mm(ORIGIN[0] + x), mm(ORIGIN[1] + y))


def netlist():
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "net.xml"
        subprocess.run(["kicad-cli", "sch", "export", "netlist", "--format", "kicadxml", "-o", str(out),
                        str(HERE / "mcu_board.kicad_sch")], check=True, capture_output=True)
        return ET.parse(out).getroot()


def courtyard(fp):
    cy = fp.GetCourtyard(pcbnew.F_CrtYd)
    return cy.BBox() if cy.OutlineCount() else fp.GetBoundingBox(False)


def pack(fps, regions):
    """Shelf packing of footprints (by courtyard) into the regions, left to right, row by row."""
    queue = list(fps)
    for x0, y0, x1, y1 in regions:
        cx, cy, row = x0, y0, 0.0
        while queue:
            fp = queue[0]
            bb = courtyard(fp)
            w, h = pcbnew.ToMM(bb.GetWidth()) + GAP, pcbnew.ToMM(bb.GetHeight()) + GAP
            if cx + w > x1:
                cx, cy, row = x0, cy + row, 0.0
            if cy + h > y1:
                break
            # move the courtyard's top left corner to (cx, cy)
            off = fp.GetPosition() - bb.GetOrigin()
            fp.SetPosition(at(cx, cy) + off)
            cx += w
            row = max(row, h)
            queue.pop(0)
    return queue


def project_rules(pro):
    """KiCad keeps the net classes and design rules in the project file, not in the board."""
    data = json.loads(pro.read_text()) if pro.exists() else {"meta": {"filename": pro.name, "version": 3}}
    rules = data.setdefault("board", {}).setdefault("design_settings", {}).setdefault("rules", {})
    rules.update({k: v for k, v in RULES.items() if k.startswith("min_")})
    net = data.setdefault("net_settings", {"meta": {"version": 4}})
    default = {"name": "Default", "priority": 2147483647, "diff_pair_width": 0.2, "diff_pair_gap": 0.15,
               "microvia_diameter": 0.3, "microvia_drill": 0.1, "wire_width": 6, "bus_width": 12, "line_style": 0,
               "pcb_color": "rgba(0, 0, 0, 0.000)", "schematic_color": "rgba(0, 0, 0, 0.000)"}
    default.update({k: v for k, v in RULES.items() if not k.startswith("min_")})
    net["classes"] = [c for c in net.get("classes", []) if c.get("name") != "Default"] + [default]
    pro.write_text(json.dumps(data, indent=2) + "\n")


def main():
    root = netlist()
    board = pcbnew.BOARD()
    board.SetCopperLayerCount(4)
    ds = board.GetDesignSettings()
    nc = ds.m_NetSettings.GetDefaultNetclass()
    nc.SetClearance(mm(0.15))
    nc.SetTrackWidth(mm(0.2))
    nc.SetViaDiameter(mm(0.6))
    nc.SetViaDrill(mm(0.3))

    nets = {}
    for n in root.iter("net"):
        name = n.get("name")
        item = pcbnew.NETINFO_ITEM(board, name.replace("/", "{slash}"))     # KiCad's escaping in net names
        board.Add(item)
        nets[name] = (item, [(node.get("ref"), node.get("pin")) for node in n.iter("node")])

    fps = {}
    for c in root.iter("comp"):
        ref = c.get("ref")
        lib, name = c.findtext("footprint").split(":")
        fp = pcbnew.FootprintLoad(str(FPDIR / f"{lib}.pretty"), name)
        fp.SetFPID(pcbnew.LIB_ID(lib, name))
        fp.SetReference(ref)
        fp.SetValue(c.findtext("value"))
        sheet = c.find("sheetpath")
        fp.SetPath(pcbnew.KIID_PATH(sheet.get("tstamps") + c.findtext("tstamps")))
        board.Add(fp)
        fps[ref] = fp

    for name, (item, nodes) in nets.items():
        for ref, pin in nodes:
            for pad in fps[ref].Pads():
                if pad.GetNumber() == pin:
                    pad.SetNet(item)

    placed = []
    for ref, (x, y, rot) in FIXED.items():
        fps[ref].SetOrientationDegrees(rot)
        fps[ref].SetPosition(at(x, y))
        placed.append(ref)
    for spec, rect in GROUPS:
        names = refs(spec)
        left = pack([fps[r] for r in names], [rect])
        if left:
            raise SystemExit(f"group {spec}: no room for {[f.GetReference() for f in left]}")
        placed += names
    missing = sorted(set(fps) - set(placed))
    twice = sorted({r for r in placed if placed.count(r) > 1})
    if missing or twice:
        raise SystemExit(f"not placed: {missing}; placed twice: {twice}")

    outline = pcbnew.PCB_SHAPE(board, pcbnew.SHAPE_T_RECT)
    outline.SetLayer(pcbnew.Edge_Cuts)
    outline.SetStart(at(0, 0))
    outline.SetEnd(at(W, H))
    outline.SetWidth(mm(0.1))
    board.Add(outline)

    for layer, net in ((pcbnew.In1_Cu, "GND"), (pcbnew.In2_Cu, "+3V3")):
        zone = pcbnew.ZONE(board)
        zone.SetLayer(layer)
        zone.SetNet(nets[net][0])
        zone.SetLocalClearance(mm(0.3))
        poly = zone.Outline()
        poly.NewOutline()
        for x, y in ((0.5, 0.5), (W - 0.5, 0.5), (W - 0.5, H - 0.5), (0.5, H - 0.5)):
            poly.Append(mm(ORIGIN[0] + x), mm(ORIGIN[1] + y))
        board.Add(zone)
    # the zones are left unfilled (KiCad fills them on DRC with --refill-zones and when plotting)

    out = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "mcu_board.kicad_pcb"
    pcbnew.SaveBoard(str(out), board)
    project_rules(out.with_suffix(".kicad_pro"))
    print(f"{len(fps)} footprints, {len(nets)} nets -> {out}")


if __name__ == "__main__":
    main()
