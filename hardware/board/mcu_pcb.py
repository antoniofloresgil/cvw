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
GAP = 1.6                               # between courtyards: room for the fanout vias

# Placement by function.  FIXED parts sit at (x, y, rotation) on the board (mm from its top left
# corner); each GROUP is packed, in the order given, into its rectangle (x0, y0, x1, y1) beside the
# part it serves.  Every footprint must be in exactly one of them.
FIXED = {
    # USB-C on the left edge level with the FT2232HL's DP/DM pins (7, 8), the ESD protection in line:
    # a 15 mm pair
    "J1": (5.0, 47.0, 270), "U1": (13.0, 49.0, 0),
    # Pmod headers, right angle: pin 1 6.6 mm in, so the plastic ends at the edge and the pins stick out
    "J5": (48.0, 6.6, 90), "J6": (66.0, 6.6, 90), "J7": (84.0, 6.6, 90),
    "H1": (3.5, 3.5, 0), "H2": (W - 3.5, 3.5, 0), "H3": (3.5, H - 3.5, 0), "H4": (W - 3.5, H - 3.5, 0),
    "U4": (24.0, 47.0, 0),                                    # FT2232HL
    "J3": (3.5, 57.5, 0),                                     # UART header, left edge beside the FT2232HL
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
    ("F1 R1 R2 U2 C1-C4 U3 C5 C6 R3 D1 R4 D2 TP1-TP3 TP6 TP7", (8, 8, 37, 31)),     # power
    ("JP1 JP2 TP4 TP5", (46.2, 15.5, 52, 40)),          # the chip's supplies: ammeter jumpers beside it
    ("Y1 C7 C8", (10, 31.6, 17.2, 43.2)),                                              # FT2232HL crystal
    ("R9-R15", (31.5, 37, 42, 56)),                                                    # FT2232HL to the chip
    ("C9-C19 FB1 R5 R6 U5 R7 R8", (8.5, 55, 42, 73)),                                 # FT2232HL supply, EEPROM
    ("C21-C23 C31-C33", (52.4, 21, 67, 29.5)),                                         # chip decoupling
    ("C40 R16 U7", (52, 37.5, 68, 46)),                                                # clock and reset
    ("TP10-TP15", (42, 46.5, 72, 51.5)),
    ("C41 R17-R19", (68, 35, 80, 46)),                                               # flash
    ("U9 C42", (42, 52, 58, 61)),                                                    # LED buffer
    ("R20-R31", (73, 47, 88.2, 61.5)),                                                 # strap resistors
    ("U10 U11 U12 U13 RV1 C43-C46 R46 R47", (78, 12, 103, 40)),                      # I2C and analog
]
POWER_NETS = ["GND", "VBUS", "+5V", "+3V3", "+1V2"]   # 0.3 mm tracks; the chip's and the FT2232HL's own supplies (tens of mA) take 0.2 mm, which fits between QFN pins
RULES = {   # mm; the default net class and the board's minimums, written into mcu_board.kicad_pro
    "clearance": 0.15, "track_width": 0.2, "via_diameter": 0.6, "via_drill": 0.3,
    "min_clearance": 0.15, "min_track_width": 0.1, "min_via_diameter": 0.4, "min_through_hole_diameter": 0.2,
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
    power = dict(default, name="Power", priority=0, track_width=0.3)
    net["classes"] = [c for c in net.get("classes", []) if c.get("name") not in ("Default", "Power")] + [default, power]
    # USB 2.0 pair: 90 ohm differential as a microstrip on F.Cu over the GND plane of JLCPCB's
    # JLC04161H-7628 stack-up (0.21 mm prepreg, er 4.4): 0.30 mm tracks 0.15 mm apart (estimate;
    # check with the maker's impedance calculator)
    usb = dict(default, name="USB", priority=1, track_width=0.3, diff_pair_width=0.3, diff_pair_gap=0.15)
    net["classes"] = [c for c in net["classes"] if c.get("name") != "USB"] + [usb]
    net["netclass_patterns"] = [{"netclass": "Power", "pattern": n} for n in POWER_NETS] + \
        [{"netclass": "USB", "pattern": n} for n in ("USB_DP", "USB_DN")]
    pro.write_text(json.dumps(data, indent=2) + "\n")


# Silkscreen.  The references of the small parts are hidden (they stay on F.Fab); a test point shows
# its net instead; connectors, jumpers and switches get what they are for.  Every visible text is
# moved to the first spot around its part that is clear of pads, other silkscreen and the board edge.
SHOW_REF = ("U", "J", "SW", "Y", "X", "F", "RV")
LABELS = {    # ref: text written beside the part
    "J1": "USB", "J2": "JTAG", "SW1": "RESET",
    "JP1": "VDD_IO", "JP2": "VDD_CORE",
    "J5": "PMOD A: CLK UART SPI", "J6": "PMOD B: GPIO0-7", "J7": "PMOD C: JTAG",
    "SW2": "BOOT STRAPS (ON = 1)\n1-5 baud divisor, 6 UART boot\n115200 baud: 1-5 OFF",
    "D1": "5V", "D2": "3V3",
}
PIN_LABELS = {  # ref: ({pad: text}, side of the pads the texts go)
    "J3": ({"1": "GND", "2": "TX", "3": "RX"}, "right"),
    "J4": ({"1": "AIN2", "2": "AIN3", "3": "DAC", "4": "GND"}, "left"),
}
TITLE = "asic_soc_rv32imac test board\nCORE-V Wally (cvw), rev A"


class Silk:
    def __init__(self, board):
        self.board = board
        self.blocked = []
        for fp in board.GetFootprints():
            for pad in fp.Pads():
                self.blocked.append(self.grow(pad.GetBoundingBox(), 0.2))
            for g in fp.GraphicalItems():
                if g.GetLayer() == pcbnew.F_SilkS and isinstance(g, pcbnew.PCB_SHAPE):
                    self.blocked.append(self.grow(g.GetBoundingBox(), 0.1))
        self.edge = pcbnew.BOX2I(at(0.6, 0.6), pcbnew.VECTOR2I(mm(W - 1.2), mm(H - 1.2)))

    @staticmethod
    def grow(box, d):
        b = pcbnew.BOX2I(box.GetOrigin(), box.GetSize())
        b.Inflate(mm(d))
        return b

    def free(self, box):
        if not self.edge.Contains(box):
            return False
        return not any(box.Intersects(b) for b in self.blocked)

    def place(self, text, around):
        """Move `text` to the first clear spot around the box `around`, horizontal or else vertical;
        True when it found one."""
        for angle in (0, 90):
            text.SetTextAngleDegrees(angle)
            if self._place(text, around):
                return True
        text.SetTextAngleDegrees(0)
        return False

    def _place(self, text, around):
        tb = text.GetBoundingBox()
        w, h = pcbnew.ToMM(tb.GetWidth()), pcbnew.ToMM(tb.GetHeight())
        c = around.GetCenter()
        L, T, R, B = (pcbnew.ToMM(v) for v in (around.GetLeft(), around.GetTop(), around.GetRight(), around.GetBottom()))
        cx, cy = pcbnew.ToMM(c.x), pcbnew.ToMM(c.y)
        for gap in (0.3, 1.0, 2.0, 3.5):
            for x, y in ((cx, T - gap - h / 2), (cx, B + gap + h / 2), (L - gap - w / 2, cy), (R + gap + w / 2, cy),
                         (L + w / 2, T - gap - h / 2), (R - w / 2, T - gap - h / 2),
                         (L + w / 2, B + gap + h / 2), (R - w / 2, B + gap + h / 2)):
                text.SetPosition(pcbnew.VECTOR2I(mm(x), mm(y)))
                box = self.grow(text.GetBoundingBox(), 0.15)
                if self.free(box):
                    self.blocked.append(box)
                    return True
        return False

    def new_text(self, s, size=1.0):
        t = pcbnew.PCB_TEXT(self.board)
        t.SetText(s)
        t.SetLayer(pcbnew.F_SilkS)
        t.SetTextSize(pcbnew.VECTOR2I(mm(size), mm(size)))
        t.SetTextThickness(mm(size * 0.15))
        self.board.Add(t)
        return t


def silkscreen(board, fps):
    silk = Silk(board)
    unplaced = []
    for ref in ("J5", "J6", "J7"):                     # under each Pmod header, centred on its pins
        t = silk.new_text(LABELS[ref], 0.9)
        t.SetPosition(at(FIXED[ref][0] + 6.35, 10.0))
        box = silk.grow(t.GetBoundingBox(), 0.15)
        if silk.free(box):
            silk.blocked.append(box)
        else:
            board.Remove(t)
            unplaced.append(f"label of {ref}")
    for ref, fp in sorted(fps.items(), key=lambda kv: -courtyard(kv[1]).GetArea()):
        field = fp.Reference()
        prefix = ref.rstrip("0123456789")
        if prefix == "TP":                         # a test point shows its net
            field.SetVisible(False)
            val = fp.Value()
            val.SetLayer(pcbnew.F_SilkS)
            val.SetVisible(True)
            val.SetTextSize(pcbnew.VECTOR2I(mm(0.8), mm(0.8)))
            val.SetTextThickness(mm(0.12))
            if not silk.place(val, courtyard(fp)):
                val.SetVisible(False)
                unplaced.append(ref)
            continue
        if prefix not in SHOW_REF or ref in ("J5", "J6", "J7"):     # the Pmod headers carry a label instead
            field.SetVisible(False)
            continue
        field.SetTextSize(pcbnew.VECTOR2I(mm(1.0), mm(1.0)))
        field.SetTextThickness(mm(0.15))
        if not silk.place(field, courtyard(fp)):
            field.SetVisible(False)
            unplaced.append(ref)
    for ref, s in LABELS.items():
        if ref in ("J5", "J6", "J7"):
            continue
        t = silk.new_text(s, 0.9 if "\n" in s or len(s) > 12 else 1.0)
        if not silk.place(t, courtyard(fps[ref])):
            board.Remove(t)
            unplaced.append(f"label of {ref}")
    for ref, (pins, side) in PIN_LABELS.items():
        for pad in fps[ref].Pads():
            if pad.GetNumber() in pins:
                t = silk.new_text(pins[pad.GetNumber()], 0.8)
                tb = t.GetBoundingBox()
                p = pad.GetPosition()
                dx = (pcbnew.ToMM(pad.GetBoundingBox().GetWidth()) / 2 + 0.9 + pcbnew.ToMM(tb.GetWidth()) / 2) * (1 if side == "right" else -1)
                t.SetPosition(pcbnew.VECTOR2I(p.x + mm(dx), p.y))
                silk.blocked.append(silk.grow(t.GetBoundingBox(), 0.15))
    title = silk.new_text(TITLE, 1.0)
    if not silk.place(title, pcbnew.BOX2I(at(17, 75), pcbnew.VECTOR2I(mm(22), mm(1)))):
        board.Remove(title)
        unplaced.append("title")
    return unplaced


def main():
    root = netlist()
    board = pcbnew.BOARD()
    board.SetCopperLayerCount(4)
    board.SetLayerType(pcbnew.In1_Cu, pcbnew.LT_POWER)       # planes: the router keeps its tracks off them
    board.SetLayerType(pcbnew.In2_Cu, pcbnew.LT_POWER)
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

    unplaced = silkscreen(board, fps)
    if unplaced:
        print(f"silkscreen: no clear spot for {unplaced}")

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


def update_values():
    """Copy the schematic's values onto the footprints of the routed board, leaving the routing alone."""
    values = {c.get("ref"): c.findtext("value") for c in netlist().iter("comp")}
    board = pcbnew.LoadBoard(str(HERE / "mcu_board.kicad_pcb"))
    changed = 0
    for fp in board.GetFootprints():
        v = values.get(fp.GetReference())
        if v is not None and fp.GetValue() != v and not fp.GetReference().startswith("TP"):
            fp.SetValue(v)
            changed += 1
    pcbnew.SaveBoard(str(HERE / "mcu_board.kicad_pcb"), board)
    print(f"{changed} values updated")


if __name__ == "__main__":
    if sys.argv[1:] == ["--update-values"]:
        update_values()
    else:
        main()
