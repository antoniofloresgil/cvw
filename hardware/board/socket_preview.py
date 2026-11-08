#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Draws socket_footprint.png from the footprint of mcu_board.pretty (pad numbers, body, stand-off areas, pin 1), to
compare with Yamaichi's drawing.  Run after socket_fp.py with the system Python (pcbnew and PIL)."""

from pathlib import Path

import pcbnew
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
S = 40                                  # pixels per mm
X0, X1, Y0, Y1 = -14.0, 16.5, -14.5, 14.5


def px(x, y):
    return ((x - X0) * S, (y - Y0) * S)


def main():
    fp = pcbnew.FootprintLoad(str(HERE / "mcu_board.pretty"), "Yamaichi_IC550-0324-007_QFN32")
    mm = pcbnew.ToMM
    im = Image.new("RGB", (int((X1 - X0) * S), int((Y1 - Y0) * S)), "white")
    d = ImageDraw.Draw(im)
    font = ImageFont.load_default(size=15)
    small = ImageFont.load_default(size=12)
    for z in fp.Zones():                                    # the stand-off keep-out areas
        bb = z.GetBoundingBox()
        x0, y0, x1, y1 = mm(bb.GetLeft()), mm(bb.GetTop()), mm(bb.GetRight()), mm(bb.GetBottom())
        if x1 - x0 > 3:
            d.rectangle([*px(x0, y0), *px(x1, y1)], fill=(255, 235, 235), outline=(200, 80, 80))
        else:
            cx, cy, r = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2
            d.ellipse([*px(cx - r, cy - r), *px(cx + r, cy + r)], fill=(255, 235, 235), outline=(200, 80, 80))
    for s in fp.GraphicalItems():                           # body, nest and pin 1 mark
        if isinstance(s, pcbnew.PCB_SHAPE) and s.GetLayer() in (pcbnew.F_SilkS, pcbnew.F_CrtYd) and s.GetShape() == pcbnew.SHAPE_T_SEGMENT:
            a, b = s.GetStart(), s.GetEnd()
            d.line([*px(mm(a.x), mm(a.y)), *px(mm(b.x), mm(b.y))],
                   fill=(0, 110, 160) if s.GetLayer() == pcbnew.F_SilkS else (160, 0, 160), width=2)
    for p in fp.Pads():
        pos = p.GetPosition()
        x, y = mm(pos.x), mm(pos.y)
        r = mm(p.GetSizeX()) / 2
        if p.GetAttribute() == pcbnew.PAD_ATTRIB_NPTH:
            d.ellipse([*px(x - r, y - r), *px(x + r, y + r)], outline=(0, 0, 0), width=2)
            d.text(px(x, y + r + 0.5), "locating 1.65", fill="black", font=small, anchor="mm")
            continue
        d.ellipse([*px(x - r, y - r), *px(x + r, y + r)], fill=(200, 120, 40))
        dr = mm(p.GetDrillSizeX()) / 2
        d.ellipse([*px(x - dr, y - dr), *px(x + dr, y + dr)], fill="white")
        num = p.GetNumber()
        if num == "33":
            d.text(px(x, y + 1.6), "33 (GND, masked)", fill="black", font=small, anchor="mm")
        else:                                               # the number above the pad, on a white tag
            tx, ty = px(x, y - 0.8)
            w = 7 * len(num) + 2
            d.rectangle([tx - w, ty - 7, tx + w, ty + 7], fill="white")
            d.text((tx, ty), num, fill=(0, 0, 160), font=small, anchor="mm")
    d.text(px(0, -12.9), "Yamaichi IC550-0324-007 QFN32 (top view, 1 mm grid ticks at the edge); body 24.5 x 22 mm, hinge on the right; pin 1 at the bottom left, pins counter-clockwise",
           fill="black", font=font, anchor="mm")
    for t in range(-12, 16):
        d.line([*px(t, Y1 - 0.5), *px(t, Y1 - 0.2)], fill="gray")
    for t in range(-12, 13):
        d.line([*px(X0 + 0.2, t), *px(X0 + 0.5, t)], fill="gray")
    out = HERE / "socket_footprint.png"
    im.save(out)
    print(f"wrote {out} {im.size}")


if __name__ == "__main__":
    main()
