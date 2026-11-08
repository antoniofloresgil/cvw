#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Routes mcu_board.kicad_pcb with Freerouting: exports the board as a Specctra DSN, runs
Freerouting without its GUI, imports the session back and saves the board with its planes filled.
The USB pair is routed first, coupled and matched (usb_pair).  The inner layers are planes (In1 GND,
In2 +3V3): every SMD pad of those nets then gets a locked via beside it (fanout), and the router
keeps to F.Cu and B.Cu for the rest.  Run with the system Python (pcbnew):
    python3 route.py [--jar freerouting.jar] [--passes 40]
On a board that already has tracks it only routes what is still unconnected (run it again when the
autorouter leaves a connection or two).
Freerouting runs in a clean environment: from VS Code's snap, Java would load the snap's libraries.
"""

import argparse
import os
import subprocess
from itertools import pairwise
from pathlib import Path

import pcbnew

HERE = Path(__file__).resolve().parent


PLANES = ("GND", "+3V3")      # the nets of In1 and In2


def usb_pair(board):
    """The USB pair, routed here and locked before the autorouter (which has no differential pairs):
    J1's D- (B7) and D+ (A6) pads are level with the FT2232HL's DM (7) and DP (8), so the pair runs
    straight and coupled on F.Cu, 0.30 mm tracks 0.20 mm apart, both the same length.  The other
    orientation's pads join with short stubs: B6 (D+) along to the ESD diode's pin 1 and up to D+; A7
    (D-) through two 0.4/0.2 mm vias and a B.Cu link to D-.  The ESD diode's D- (pin 4) reaches the
    line the same way, and its twin pins (1-6, 3-4) are joined under its body.  Returns the length of each line between the connector and the FT2232HL."""
    mm = pcbnew.FromMM
    fp = {f.GetReference(): f for f in board.GetFootprints()}

    def pad(ref, n):
        return next(p for p in fp[ref].Pads() if p.GetNumber() == n)

    dn, dp = board.FindNet("USB_DN"), board.FindNet("USB_DP")
    b7, a6, a7, b6 = (pad("J1", n).GetPosition() for n in ("B7", "A6", "A7", "B6"))
    dm, dpp = pad("U4", "7").GetPosition(), pad("U4", "8").GetPosition()
    e1, e4 = pad("U1", "1").GetPosition(), pad("U1", "4").GetPosition()
    e6, e3 = pad("U1", "6").GetPosition(), pad("U1", "3").GetPosition()
    if b7.y != dm.y or a6.y != dpp.y:
        raise SystemExit("USB pair: J1 and the FT2232HL's USB pins are not level; move J1 or U4")
    V = pcbnew.VECTOR2I

    def track(a, b, net, width=0.3, layer=pcbnew.F_Cu):
        t = pcbnew.PCB_TRACK(board)
        t.SetStart(a)
        t.SetEnd(b)
        t.SetWidth(mm(width))
        t.SetLayer(layer)
        t.SetNet(net)
        t.SetLocked(True)
        board.Add(t)

    def via(at, net):
        v = pcbnew.PCB_VIA(board)
        v.SetPosition(at)
        v.SetWidth(mm(0.4))
        v.SetDrill(mm(0.2))
        v.SetNet(net)
        v.SetLocked(True)
        board.Add(v)

    track(e1, e6, dp, 0.2)                                      # the ESD diode's twin pins, under its body
    track(e3, e4, dn, 0.2)
    corner = V(e1.x, b6.y)                                      # B6 along to the ESD pin 1, which rises to D+
    track(b6, corner, dp, 0.2)
    track(corner, e1, dp, 0.2)
    track(e1, V(e1.x, a6.y), dp, 0.2)
    v1 = V(b7.x + mm(1.25), a7.y + mm(0.025))                   # A7 down between D+ and the B6 stub
    v2 = V(v1.x + mm(0.7), b7.y)                                # and up again onto D-
    track(a7, v1, dn, 0.2)
    via(v1, dn)
    track(v1, v2, dn, 0.2, pcbnew.B_Cu)
    via(v2, dn)
    v3 = V(e4.x + mm(1.05), e4.y)                               # ESD pin 4 under D+ onto D-
    v4 = V(v3.x, b7.y)
    track(e4, v3, dn, 0.2)
    via(v3, dn)
    track(v3, v4, dn, 0.2, pcbnew.B_Cu)
    via(v4, dn)
    # VBUS: the connector's two pairs of VBUS pads sit either side of the pair; a via in each (at the
    # pad's inner half) and a B.Cu track under the connector join them
    vb = board.FindNet("VBUS")
    upper, lower = sorted({pad("J1", n).GetPosition().y for n in ("A4", "A9", "B4", "B9")})
    vx = b7.x + mm(0.25)
    via(V(vx, upper), vb)
    via(V(vx, lower), vb)
    track(V(vx, upper), V(vx, lower), vb, 0.3, pcbnew.B_Cu)
    # the pair, broken at every via and junction on it: the router (and its DSN) only joins a track
    # to what sits at one of its ends
    for net, start, stops, end in ((dn, b7, [v2, v4], dm), (dp, a6, [V(e1.x, a6.y)], dpp)):
        points = [start] + sorted(stops, key=lambda q: q.x) + [end]
        for a, b in pairwise(points):
            track(a, b, net)
    return pcbnew.ToMM(dm.x - b7.x), pcbnew.ToMM(dpp.x - a6.x)


def cleanup(board):
    """Remove what the router leaves behind: isolated tracks shorter than 0.01 mm, and vias of a signal net that
    no track reaches on one side or the other.  Everything is found first and removed at the end:
    removing while KiCad's track list is being read breaks its Python binding."""
    items = list(board.GetTracks())
    tracks = [t for t in items if not isinstance(t, pcbnew.PCB_VIA)]
    count = {}
    for t in tracks:
        for q in (t.GetStart(), t.GetEnd()):
            key = (t.GetNetCode(), t.GetLayer(), q.x, q.y)
            count[key] = count.get(key, 0) + 1
    # a tiny track no other track meets at either end: the router's dot on a pad (a tiny track that
    # joins two others at a bend is kept)
    stubs = [t for t in tracks if t.GetLength() < pcbnew.FromMM(0.01) and not t.IsLocked()
             and all(count[(t.GetNetCode(), t.GetLayer(), q.x, q.y)] == 1 for q in (t.GetStart(), t.GetEnd()))]
    ends = {}
    for t in tracks:
        if t in stubs:
            continue
        for q in (t.GetStart(), t.GetEnd()):
            ends.setdefault((t.GetNetCode(), q.x, q.y), set()).add(t.GetLayer())
    dangling = [v for v in items if isinstance(v, pcbnew.PCB_VIA) and not v.IsLocked() and v.GetNetname() not in PLANES
                and len(ends.get((v.GetNetCode(), v.GetPosition().x, v.GetPosition().y), ())) < 2]
    for item in stubs + dangling:
        board.Remove(item)
    return len(stubs) + len(dangling)


def seg_dist(p, a, b):
    """Distance from point p to segment a-b (nm)."""
    ax, ay, bx, by, px, py = a.x, a.y, b.x, b.y, p.x, p.y
    dx, dy = bx - ax, by - ay
    t = 0.0 if dx == dy == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return ((px - ax - t * dx) ** 2 + (py - ay - t * dy) ** 2) ** 0.5


def fanout(board):
    """A locked via beside every SMD pad of a plane net, joined to it by a short track, so the router
    only has the signals left: outward from the pad (along its long side for an IC, along the part's
    axis for a two-pad part), the via's edge 0.15 mm past the pad's.  A pad at the footprint's centre
    (an exposed pad) gets four vias inside it.  A via that would come closer than the clearance to a
    pad, via or track of another net, or duplicate one of its own net, is left out: the router
    connects that pad."""
    mm = pcbnew.FromMM
    via_r, clear, track_w = mm(0.3), mm(0.15), mm(0.3)
    nets = {n: board.FindNet(n) for n in PLANES}
    pads = [pad for fp in board.GetFootprints() for pad in fp.Pads()]
    vias, tracks = [], []          # (position, net name), (start, end, net name)

    def fits(v, start, net):
        if any(pad.GetNetname() != net and pad.HitTest(v, via_r + clear) for pad in pads):
            return False
        for q, n in vias:
            d = ((v.x - q.x) ** 2 + (v.y - q.y) ** 2) ** 0.5
            if d < 2 * via_r + (clear if n != net else mm(0.2)):
                return False
            if start is not None and n != net and seg_dist(q, start, v) < via_r + clear + track_w / 2:
                return False
        return all(seg_dist(v, a, b) >= via_r + clear + track_w / 2 for a, b, n in tracks if n != net)

    def add_via(v, name):
        via = pcbnew.PCB_VIA(board)
        via.SetPosition(v)
        via.SetWidth(mm(0.6))
        via.SetDrill(mm(0.3))
        via.SetNet(nets[name])
        via.SetLocked(True)
        board.Add(via)
        vias.append((v, name))

    for fp in board.GetFootprints():
        centre = fp.GetPosition()
        for pad in fp.Pads():
            name = pad.GetNetname()
            if name not in PLANES or pad.GetAttribute() != pcbnew.PAD_ATTRIB_SMD:
                continue
            p = pad.GetPosition()
            d = p - centre
            box = pad.GetBoundingBox()
            if (d.x ** 2 + d.y ** 2) ** 0.5 < mm(0.3):
                q = mm(0.6)
                for sx in (-1, 1):
                    for sy in (-1, 1):
                        v = pcbnew.VECTOR2I(p.x + sx * q, p.y + sy * q)
                        if fits(v, None, name):
                            add_via(v, name)
                continue
            if len(fp.Pads()) > 2 and box.GetWidth() != box.GetHeight():
                along_x = box.GetWidth() > box.GetHeight()
            else:
                along_x = abs(d.x) >= abs(d.y)
            ux, uy = (1 if d.x > 0 else -1, 0) if along_x else (0, 1 if d.y > 0 else -1)
            reach = (box.GetWidth() if along_x else box.GetHeight()) / 2 + mm(0.45)
            v = pcbnew.VECTOR2I(int(p.x + ux * reach), int(p.y + uy * reach))
            if not fits(v, p, name):
                continue
            track = pcbnew.PCB_TRACK(board)
            track.SetStart(p)
            track.SetEnd(v)
            track.SetWidth(track_w)
            track.SetLayer(pcbnew.B_Cu if fp.IsFlipped() else pcbnew.F_Cu)      # the side of the part
            track.SetNet(nets[name])
            track.SetLocked(True)
            board.Add(track)
            tracks.append((p, v, name))
            add_via(v, name)
    return len(vias)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--jar", default=os.environ.get("FREEROUTING_JAR", "/datos/tmp/cvw-builds/tools/freerouting/freerouting-2.5.0.jar"))
    ap.add_argument("--passes", type=int, default=40)
    ap.add_argument("--board", default=str(HERE / "mcu_board.kicad_pcb"))
    args = ap.parse_args()
    board_file = Path(args.board)
    dsn, ses = board_file.with_suffix(".dsn"), board_file.with_suffix(".ses")
    board = pcbnew.LoadBoard(str(board_file))
    if any(isinstance(t, pcbnew.PCB_TRACK) for t in board.GetTracks()):
        # a routed board: only what is still unconnected is routed, around everything already there
        print("the board has tracks: routing only what is left", flush=True)
    else:
        dn_len, dp_len = usb_pair(board)
        print(f"USB pair: D- {dn_len:.2f} mm, D+ {dp_len:.2f} mm", flush=True)
        print(f"fanout: {fanout(board)} vias to the planes", flush=True)
    if not pcbnew.ExportSpecctraDSN(board, str(dsn)):
        raise SystemExit("DSN export failed")
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}
    subprocess.run(["java", "-jar", args.jar, "-de", str(dsn), "-do", str(ses), "-mp", str(args.passes),
                    "--gui.enabled=false"], check=True, env=env)
    if not pcbnew.ImportSpecctraSES(board, str(ses)):
        raise SystemExit("SES import failed")
    print(f"clean-up: {cleanup(board)} zero-length tracks and dangling vias removed", flush=True)
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    pcbnew.SaveBoard(str(board_file), board)
    print(f"routed: {board_file}")


if __name__ == "__main__":
    main()
