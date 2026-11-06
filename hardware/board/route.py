#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Routes mcu_board.kicad_pcb with Freerouting: exports the board as a Specctra DSN, runs
Freerouting without its GUI, imports the session back and saves the board with its planes filled.
The inner layers are planes (In1 GND, In2 +3V3): every SMD pad of those nets first gets a locked
via beside it (fanout), and the router keeps to F.Cu and B.Cu for the rest.  Run with the system Python (pcbnew):
    python3 route.py [--jar freerouting.jar] [--passes 40]
Freerouting runs in a clean environment: from VS Code's snap, Java would load the snap's libraries.
"""

import argparse
import os
import subprocess
from pathlib import Path

import pcbnew

HERE = Path(__file__).resolve().parent


PLANES = ("GND", "+3V3")      # the nets of In1 and In2


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
            track.SetLayer(pad.GetPrincipalLayer())
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
        raise SystemExit("the board already has tracks: regenerate it with mcu_pcb.py first")
    print(f"fanout: {fanout(board)} vias to the planes", flush=True)
    if not pcbnew.ExportSpecctraDSN(board, str(dsn)):
        raise SystemExit("DSN export failed")
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}
    subprocess.run(["java", "-jar", args.jar, "-de", str(dsn), "-do", str(ses), "-mp", str(args.passes),
                    "--gui.enabled=false"], check=True, env=env)
    if not pcbnew.ImportSpecctraSES(board, str(ses)):
        raise SystemExit("SES import failed")
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    pcbnew.SaveBoard(str(board_file), board)
    print(f"routed: {board_file}")


if __name__ == "__main__":
    main()
