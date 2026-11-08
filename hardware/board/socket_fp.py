#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Writes mcu_board.pretty/Yamaichi_IC550-0324-007_QFN32.kicad_mod: the footprint of the chip's QFN32 test socket
(Yamaichi IC550-0324-007-G, 5 x 5 mm package, 0.5 mm pitch, hinged lid), from Yamaichi's drawing A111332-001
(https://www.waveshare.com/datasheet/Test_Socket_PDF/QFN/IC550-0324-007-x.pdf).  Run with the Python that has
KiCad's pcbnew (the system Python):  python3 socket_fp.py

What the drawing gives, viewed from the top of the socket (x to the right, y down, origin at the centre of the
package):
  * 32 contact holes, 0.50 mm (+0.1/0) in diameter.  A side has 8 contacts at the package's 0.5 mm pitch, over 3.5 mm;
    their tails go to three rows of the pattern, 1 mm apart, on squares of 7.5, 9.5 and 11.5 mm: the contact k of a
    side (k = 0..7 along the side, in the clockwise direction) is in the row k mod 3 counted from the inside, so every
    row has its holes 1.5 mm apart and the neighbouring contacts are 0.5 mm along and 1 mm across.  The four sides
    repeat the pattern turned by 90 degrees.
  * a hole of 0.80 mm (+0.05/0) at the centre for the ground pin, which presses on the package's exposed pad, and
    note 1: "Center hole on the P.C.B. must be masked to prevent solders from flowing into the center hole".
  * two locating holes of 1.60 mm (+0.1/0) at (+8, +7) and (-8, -7).
  * five stand-off areas (the socket rests on them; "keep the board trace out of area"): four squares of 5 x 5 mm
    centred at (+-8.5, +-8.5) and a circle of 2.5 mm at the centre.
  * the body is 24.5 x 22 mm: 11 mm to the left of the package, 13.5 to the right (the hinge is on the right) and 11
    above and below.
  * the pin 1 indicator is at the bottom left corner of the package's nest: the package goes in with its pin 1
    corner there, which turns it 90 degrees counter-clockwise from the usual drawing.  Pins 1-8 are therefore on the
    bottom side from left to right, 9-16 up the right side, 17-24 along the top from right to left and 25-32 down
    the left side, and pad 33 is the centre pin (the exposed pad).

What it assumes, which the drawing does not say: that the tail of the contact under a package pad is at the same
position along its side as the pad.  Check with a multimeter on the first socket (a pin of the package against the
hole of the same number) before ordering many boards.
"""

from pathlib import Path

import pcbnew

HERE = Path(__file__).resolve().parent
NAME = "Yamaichi_IC550-0324-007_QFN32"
PITCH = 0.5
ROW0 = 3.75                  # distance from the centre of the nearest row of holes: squares of 7.5, 9.5, 11.5 mm
ROW_STEP = 1.0
CONTACT_DRILL, CONTACT_PAD = 0.55, 0.9     # finished hole 0.50 +0.1/0; 0.2 mm of annular ring
GND_DRILL, GND_PAD = 0.85, 1.4             # 0.80 +0.05/0
LOCATING_DRILL = 1.65                      # 1.60 +0.1/0, not plated
BODY = (-11.0, -11.0, 13.5, 11.0)          # x0, y0, x1, y1
STANDOFFS = [(sx * 8.5, sy * 8.5) for sx in (-1, 1) for sy in (-1, 1)]
STANDOFF_SIZE = 5.0
CENTRE_KEEPOUT_D = 2.5


def mm(v):
    return pcbnew.FromMM(v)


def vec(x, y):
    return pcbnew.VECTOR2I(mm(x), mm(y))


def hole(pin):
    """Position (x, y) of the hole of contact `pin` (1..32)."""
    side, i = divmod(pin - 1, 8)
    k = 7 - i                                  # along the side, clockwise; the pins go counter-clockwise
    d = ROW0 + (k % 3) * ROW_STEP
    along = -1.75 + PITCH * k
    return [(-along, d),                       # pins 1-8: the bottom side, left to right
            (d, along),                        # 9-16: the right side, bottom to top
            (along, -d),                       # 17-24: the top side, right to left
            (-d, -along)][side]                # 25-32: the left side, top to bottom


def pad(fp, number, x, y, size, drill, plated=True, mask=True):
    p = pcbnew.PAD(fp)
    p.SetNumber(str(number))
    p.SetShape(pcbnew.PAD_SHAPE_CIRCLE)
    p.SetSize(pcbnew.VECTOR2I(mm(size), mm(size)))
    p.SetDrillSize(pcbnew.VECTOR2I(mm(drill), mm(drill)))
    p.SetPosition(vec(x, y))
    layers = pcbnew.LSET()
    if plated:
        p.SetAttribute(pcbnew.PAD_ATTRIB_PTH)
        layers = pcbnew.LSET.AllCuMask()
        if mask:
            layers.AddLayer(pcbnew.F_Mask)
            layers.AddLayer(pcbnew.B_Mask)
    else:
        p.SetAttribute(pcbnew.PAD_ATTRIB_NPTH)
        layers.AddLayer(pcbnew.F_Cu)
        layers.AddLayer(pcbnew.B_Cu)
        layers.AddLayer(pcbnew.F_Mask)
        layers.AddLayer(pcbnew.B_Mask)
    p.SetLayerSet(layers)
    fp.Add(p)
    return p


def line(fp, layer, a, b, width):
    s = pcbnew.PCB_SHAPE(fp)
    s.SetShape(pcbnew.SHAPE_T_SEGMENT)
    s.SetLayer(layer)
    s.SetStart(vec(*a))
    s.SetEnd(vec(*b))
    s.SetWidth(mm(width))
    fp.Add(s)


def rect(fp, layer, x0, y0, x1, y1, width):
    for a, b in (((x0, y0), (x1, y0)), ((x1, y0), (x1, y1)), ((x1, y1), (x0, y1)), ((x0, y1), (x0, y0))):
        line(fp, layer, a, b, width)


def keepout(fp, points):
    """A rule area on the top copper that keeps tracks, vias and copper pours out (pads and parts may be there)."""
    z = pcbnew.ZONE(fp)
    z.SetIsRuleArea(True)
    z.SetLayer(pcbnew.F_Cu)
    z.SetDoNotAllowTracks(True)
    z.SetDoNotAllowVias(True)
    z.SetDoNotAllowZoneFills(True)
    z.SetDoNotAllowPads(False)
    z.SetDoNotAllowFootprints(False)
    z.SetZoneName("socket stand-off")
    outline = pcbnew.SHAPE_LINE_CHAIN()
    for x, y in points:
        outline.Append(mm(x), mm(y))
    outline.SetClosed(True)
    z.Outline().AddOutline(outline)
    fp.Add(z)


def text(fp, layer, s, x, y, size=1.0):
    t = pcbnew.PCB_TEXT(fp)
    t.SetText(s)
    t.SetLayer(layer)
    t.SetPosition(vec(x, y))
    t.SetTextSize(pcbnew.VECTOR2I(mm(size), mm(size)))
    t.SetTextThickness(mm(size * 0.15))
    fp.Add(t)


def build():
    fp = pcbnew.FOOTPRINT(None)
    fp.SetFPID(pcbnew.LIB_ID("mcu_board", NAME))
    fp.SetLibDescription("Yamaichi IC550-0324-007-G QFN32 5x5 mm 0.5 mm pitch test socket, through-hole (drawing A111332-001); "
                      "pin 1 at the bottom left of the nest, pins counter-clockwise, pad 33 is the centre ground pin")
    fp.SetKeywords("QFN32 test socket Yamaichi IC550 burn-in")
    fp.SetAttributes(pcbnew.FP_THROUGH_HOLE)

    for pin in range(1, 33):
        x, y = hole(pin)
        pad(fp, pin, x, y, CONTACT_PAD, CONTACT_DRILL)
    pad(fp, 33, 0.0, 0.0, GND_PAD, GND_DRILL, mask=False)        # note 1: the centre hole is masked (tented)
    for x, y in ((8.0, 7.0), (-8.0, -7.0)):
        pad(fp, "", x, y, LOCATING_DRILL, LOCATING_DRILL, plated=False)

    for cx, cy in STANDOFFS:
        h = STANDOFF_SIZE / 2
        keepout(fp, [(cx - h, cy - h), (cx + h, cy - h), (cx + h, cy + h), (cx - h, cy + h)])
    import math
    keepout(fp, [(CENTRE_KEEPOUT_D / 2 * math.cos(2 * math.pi * i / 24), CENTRE_KEEPOUT_D / 2 * math.sin(2 * math.pi * i / 24))
                 for i in range(24)])

    x0, y0, x1, y1 = BODY
    rect(fp, pcbnew.F_CrtYd, x0 - 0.25, y0 - 0.25, x1 + 0.25, y1 + 0.25, 0.05)
    rect(fp, pcbnew.F_Fab, x0, y0, x1, y1, 0.1)
    rect(fp, pcbnew.F_SilkS, x0 - 0.1, y0 - 0.1, x1 + 0.1, y1 + 0.1, 0.12)
    rect(fp, pcbnew.F_SilkS, -2.5, -2.5, 2.5, 2.5, 0.12)                    # the package's nest, 5 x 5
    # the pin 1 indicator: a triangle at the bottom left corner of the nest, as on the drawing
    line(fp, pcbnew.F_SilkS, (-3.4, 3.6), (-2.6, 3.6), 0.15)
    line(fp, pcbnew.F_SilkS, (-2.6, 3.6), (-3.4, 2.8), 0.15)
    line(fp, pcbnew.F_SilkS, (-3.4, 2.8), (-3.4, 3.6), 0.15)
    text(fp, pcbnew.F_SilkS, "1", -4.3, 4.4, 1.0)
    text(fp, pcbnew.F_SilkS, "hinge", 11.0, 0.0, 1.0)
    fp.Reference().SetText("U**")
    fp.Reference().SetPosition(vec(0, -12.5))
    fp.Reference().SetLayer(pcbnew.F_SilkS)
    fp.Reference().SetTextSize(pcbnew.VECTOR2I(mm(1.0), mm(1.0)))
    fp.Value().SetText(NAME)
    fp.Value().SetPosition(vec(0, 12.5))
    fp.Value().SetLayer(pcbnew.F_Fab)
    fp.Value().SetTextSize(pcbnew.VECTOR2I(mm(1.0), mm(1.0)))
    return fp


def main():
    lib = HERE / "mcu_board.pretty"
    lib.mkdir(exist_ok=True)
    pcbnew.PCB_IO_KICAD_SEXPR().FootprintSave(str(lib), build())
    print(f"wrote {lib / (NAME + '.kicad_mod')}")


if __name__ == "__main__":
    main()
