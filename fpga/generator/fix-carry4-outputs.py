#!/usr/bin/env python3
"""
fix-carry4-outputs.py

Make every CARRY4 in a Yosys JSON netlist placeable by nextpnr-xilinx's atomic
CARRY4 packer.

In a 7-series slice, the sum O[i] and the carry CO[i] of carry position i leave
the slice through the same output mux (AMUX..DMUX), so a CARRY4 whose O[i] and
CO[i] (i < 3) both feed logic outside the carry chain has no legal placement.
Yosys produces such cells (e.g. an adder whose intermediate carry is also used
by a comparison).  Inside the CARRY4, O[i+1] = S[i+1] ^ CO[i], so those uses of
CO[i] are moved to a LUT2 computing O[i+1] ^ S[i+1]; both signals can leave the
slice.  That makes O[i+1] used, so position i+1 is checked next.  CO[3] leaves
through COUT and needs no fix.

usage: fix-carry4-outputs.py <in.json> <out.json>

A component of the CORE-V-WALLY configurable RISC-V project.
https://github.com/openhwfoundation/cvw

SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""

import collections
import json
import sys


def external_users(cells, users, bit):
    """Users of a carry bit other than the next CARRY4 in its chain."""
    return [u for u in users[bit] if not (cells[u[0]]["type"] == "CARRY4" and u[1] == "CI")]


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with open(src) as f:
        design = json.load(f)
    fixed = 0
    for module in design["modules"].values():
        cells = module.get("cells", {})
        next_bit = 1 + max((b for c in cells.values() for bits in c["connections"].values()
                            for b in bits if isinstance(b, int)), default=1)
        next_bit = max(next_bit, 1 + max((b for n in module.get("netnames", {}).values()
                                          for b in n["bits"] if isinstance(b, int)), default=1))
        # Users of each net bit: (cell, port, index).
        users = collections.defaultdict(list)
        for name, cell in cells.items():
            for port, bits in cell["connections"].items():
                if cell["port_directions"].get(port) == "input":
                    for i, b in enumerate(bits):
                        if isinstance(b, int):
                            users[b].append((name, port, i))

        new_cells = {}
        for name in sorted(cells):
            cell = cells[name]
            if cell["type"] != "CARRY4":
                continue
            o, co, s = (cell["connections"][p] for p in ("O", "CO", "S"))
            for i in range(3):
                if not (isinstance(o[i], int) and isinstance(co[i], int) and isinstance(o[i + 1], int)):
                    continue
                moved = external_users(cells, users, co[i])
                if not users[o[i]] or not moved:
                    continue
                net = next_bit
                next_bit += 1
                lut = f"{name}$co{i}_xor"
                new_cells[lut] = {
                    "hide_name": 1, "type": "LUT2",
                    "parameters": {"INIT": "0110"},
                    "attributes": {},
                    "port_directions": {"I0": "input", "I1": "input", "O": "output"},
                    "connections": {"I0": [o[i + 1]], "I1": [s[i + 1]], "O": [net]},
                }
                for user, port, index in moved:
                    cells[user]["connections"][port][index] = net
                    users[co[i]].remove((user, port, index))
                    users[net].append((user, port, index))
                users[o[i + 1]].append((lut, "I0", 0))
                if isinstance(s[i + 1], int):
                    users[s[i + 1]].append((lut, "I1", 0))
                fixed += 1
        cells.update(new_cells)
    with open(dst, "w") as f:
        json.dump(design, f)
    print(f"fix-carry4-outputs: {fixed} CARRY4 carry output(s) recomputed with a LUT2")


if __name__ == "__main__":
    main()
