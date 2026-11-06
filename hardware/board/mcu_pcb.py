#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Places the test board's PCB from the schematic: reads the netlist (kicad-cli), loads every
footprint from KiCad's libraries, gives each pad its net and packs the parts of each schematic sheet
into a region of a 110 x 85 mm four-layer board (In1 GND, In2 +3V3).  The connectors sit on the
edges: USB-C on the left, the Pmod headers on top.  Run with the Python that has KiCad's pcbnew
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

# Regions (x0, y0, x1, y1 on the board) each sheet's parts are packed into, in order
REGIONS = {
    "/power/": [(13, 8, 40, 30)],
    "/debug/": [(8, 32, 44, 78)],
    "/chip/": [(42, 19, 72, 50)],
    "/peripherals/": [(74, 19, 103, 50), (46, 52, 103, 78), (8, 78, 103, 84)],
}
FIXED = {   # ref: (x, y, rotation in degrees); connectors on the edges
    "J1": (5.0, 19.0, 270),
    # Pmod headers, right angle: pin 1 6.6 mm in, so the plastic ends at the edge and the pins stick out
    "J5": (48.0, 6.6, 90), "J6": (66.0, 6.6, 90), "J7": (84.0, 6.6, 90),
    "H1": (3.5, 3.5, 0), "H2": (W - 3.5, 3.5, 0), "H3": (3.5, H - 3.5, 0), "H4": (W - 3.5, H - 3.5, 0),
}
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

    by_sheet, fps = {}, {}
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
        by_sheet.setdefault(sheet.get("names"), []).append(fp)

    for name, (item, nodes) in nets.items():
        for ref, pin in nodes:
            for pad in fps[ref].Pads():
                if pad.GetNumber() == pin:
                    pad.SetNet(item)

    for ref, (x, y, rot) in FIXED.items():
        fps[ref].SetOrientationDegrees(rot)
        fps[ref].SetPosition(at(x, y))
    left = []
    for sheet, region in REGIONS.items():
        movable = [fp for fp in by_sheet[sheet] if fp.GetReference() not in FIXED]
        # largest first, so the ICs anchor each region and the passives fill in
        movable.sort(key=lambda f: -courtyard(f).GetArea())
        left += pack(movable, region)
    if left:
        raise SystemExit(f"no room for {[f.GetReference() for f in left]}")

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
