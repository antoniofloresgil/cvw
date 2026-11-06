#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Writes KiCad 10 schematics from a Python description: parts of the official libraries (or symbols
made here), the nets of each pin, and nothing else.  Every connected pin gets a short wire and a
label (power nets a power symbol), so the netlist is exactly what the description says.  Standard
library only."""

import re
import uuid
from pathlib import Path

SYMDIR = Path("/usr/share/kicad/symbols")
GRID = 2.54
NAMESPACE = uuid.UUID("5d0c4b0e-6f1e-4c55-9b0b-0f0a5e5a7d11")


def uid(*parts):
    """Deterministic UUIDs: regenerating the board does not change the files."""
    return str(uuid.uuid5(NAMESPACE, "/".join(map(str, parts))))


class Q(str):
    """A quoted string in an s-expression."""


def parse(text):
    tokens = re.findall(r'"(?:[^"\\]|\\.)*"|\(|\)|[^\s()"]+', text)
    pos = 0

    def node():
        nonlocal pos
        tok = tokens[pos]
        pos += 1
        if tok == "(":
            out = []
            while tokens[pos] != ")":
                out.append(node())
            pos += 1
            return out
        if tok.startswith('"'):
            return Q(tok[1:-1].replace('\\"', '"').replace("\\\\", "\\"))
        return tok

    return node()


def dump(x, level=0):
    pad = "\t" * level
    if isinstance(x, Q):
        return '"' + x.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(x, str):
        return x
    if all(not isinstance(i, list) for i in x):
        return "(" + " ".join(dump(i) for i in x) + ")"
    head = [dump(i) for i in x if not isinstance(i, list)]
    out = pad + "(" + " ".join(head)
    for i in x:
        if isinstance(i, list):
            out += "\n" + pad + "\t" + dump(i, level + 1).lstrip("\t") if all(not isinstance(j, list) for j in i) \
                else "\n" + dump(i, level + 1)
    return out + "\n" + pad + ")"


def find(node, name):
    return [c for c in node if isinstance(c, list) and c and c[0] == name]


_libs = {}


def library(name):
    if name not in _libs:
        _libs[name] = {s[1]: s for s in find(parse((SYMDIR / f"{name}.kicad_sym").read_text()), "symbol")}
    return _libs[name]


def flatten(lib, name):
    """The symbol with `extends` resolved, as the schematic embeds it (named `lib:name`)."""
    sym = library(lib)[name]
    ext = find(sym, "extends")
    if not ext:
        out = [sym[0], Q(f"{lib}:{name}")] + [c for c in sym[2:]]
    else:
        parent = flatten(lib, ext[0][1])
        own = {c[1]: c for c in find(sym, "property")}
        out = [parent[0], Q(f"{lib}:{name}")]
        for c in parent[2:]:
            if isinstance(c, list) and c[0] == "property" and c[1] in own:
                out.append(own[c[1]])
            elif isinstance(c, list) and c[0] == "symbol":
                out.append([c[0], Q(c[1].replace(parent[1].split(":")[1], name, 1))] + c[2:])
            else:
                out.append(c)
    return out


def pins_of(sym):
    """[(unit, number, name, x, y, angle)] of a flattened symbol."""
    result = []
    for sub in find(sym, "symbol"):
        unit = int(sub[1].rsplit("_", 2)[1])
        for p in find(sub, "pin"):
            at = find(p, "at")[0]
            result.append((unit, str(find(p, "number")[0][1]), str(find(p, "name")[0][1]),
                           float(at[1]), float(at[2]), int(float(at[3]))))
    return result


def custom_symbol(name, left, right, reference="U", footprint="", width=None):
    """A box symbol: left/right are [(pin number, name, electrical type)] top to bottom."""
    rows = max(len(left), len(right))
    height = (rows + 1) * GRID
    width = width or 20.32
    top = height / 2
    sym = ["symbol", Q(name), ["exclude_from_sim", "no"], ["in_bom", "yes"], ["on_board", "yes"]]
    for pname, val, y, hide in (("Reference", reference, top + 1.27, False), ("Value", name, -top - 1.27, False),
                                ("Footprint", footprint, 0, True), ("Datasheet", "", 0, True)):
        prop = ["property", Q(pname), Q(val), ["at", "0", str(y), "0"],
                ["effects", ["font", ["size", "1.27", "1.27"]]] + ([["hide", "yes"]] if hide else [])]
        sym.append(prop)
    body = ["symbol", Q(f"{name.split(':')[-1]}_1_1"),
            ["rectangle", ["start", str(-width / 2), str(top)], ["end", str(width / 2), str(-top)],
             ["stroke", ["width", "0.254"], ["type", "default"]], ["fill", ["type", "background"]]]]
    for side, pins, x, angle in (("l", left, -width / 2 - 5.08, 0), ("r", right, width / 2 + 5.08, 180)):
        for i, (number, pname, etype) in enumerate(pins):
            body.append(["pin", etype, "line", ["at", str(x), str(top - GRID * (i + 1)), str(angle)], ["length", "5.08"],
                         ["name", Q(pname), ["effects", ["font", ["size", "1.27", "1.27"]]]],
                         ["number", Q(str(number)), ["effects", ["font", ["size", "1.27", "1.27"]]]]])
    sym.append(body)
    return sym


class Sheet:
    def __init__(self, project, name, root_uuid, sheet_uuid, paper="A3", title=""):
        self.project, self.name, self.paper, self.title = project, name, paper, title
        self.root_uuid, self.sheet_uuid = root_uuid, sheet_uuid
        self.libsyms = {}
        self.items = []
        self.refs = {}
        self.parts = []
        self.width = {"A4": 297, "A3": 420, "A2": 594, "A1": 841}[paper]
        self.cursor, self.row, self.bottom = [15, 20], 0, 0

    def _symbol(self, lib, name):
        key = f"{lib}:{name}"
        if key not in self.libsyms:
            self.libsyms[key] = custom_symbol_cache[key] if lib == "mcu_board" else flatten(lib, name)
        return self.libsyms[key]

    def _place(self, pins, nets, unit):
        """Shelf packing, left to right then down: the box of the part's pins plus the wires and labels
        that leave them, with a gap of 5 mm."""
        xs, ys = [0.0], [0.0]
        for p in pins:
            if p[0] not in (0, unit):
                continue
            net = nets.get(p[1], nets.get(p[2]))
            dx, dy = {0: (-1, 0), 180: (1, 0), 90: (0, 1), 270: (0, -1)}[p[5]]
            reach = 0 if net is None else 1 if net == "NC" else GRID + (3 if net in POWER else len(net) * 1.0 + 4)
            for t in (0, reach):
                xs.append(p[3] + dx * t)
                ys.append(-p[4] + dy * t)
        w = max(xs) - min(xs) + 5
        h = max(ys) - min(ys) + 5
        if self.cursor[0] + w > self.width - 15:
            self.cursor = [15, self.cursor[1] + self.row]
            self.row = 0
        x = self.cursor[0] - min(xs)
        y = self.cursor[1] - min(ys)
        self.cursor[0] += w
        self.row = max(self.row, h)
        self.bottom = max(self.bottom, self.cursor[1] + h)
        return x, y

    def add(self, lib, name, ref, value, nets, footprint=None, unit=1, x=None, y=None, bom=True):
        """Place a part; `nets` maps a pin number (or name) to a net, "NC" for a no-connect."""
        sym = self._symbol(lib, name)
        pins = pins_of(sym)
        used = set()
        if x is None:
            x, y = self._place(pins, nets, unit)
        props = {"Reference": ref, "Value": value}
        if footprint:
            props["Footprint"] = footprint
        fp = footprint or next((str(c[2]) for c in find(sym, "property") if c[1] == "Footprint"), "")
        sx, sy = round(x / GRID) * GRID, round(y / GRID) * GRID
        inst = ["symbol", ["lib_id", Q(f"{lib}:{name}")], ["at", f"{sx:g}", f"{sy:g}", "0"], ["unit", str(unit)],
                ["exclude_from_sim", "no"], ["in_bom", "yes" if bom else "no"], ["on_board", "yes"], ["dnp", "no"],
                ["uuid", Q(uid(self.name, ref, "sym"))]]
        for k, v in (("Reference", ref), ("Value", value), ("Footprint", fp), ("Datasheet", "")):
            hide = k in ("Footprint", "Datasheet")
            inst.append(["property", Q(k), Q(v), ["at", f"{sx:g}", f"{sy - 5.08:g}" if k == "Reference" else f"{sy + 5.08:g}", "0"],
                         ["effects", ["font", ["size", "1.27", "1.27"]]] + ([["hide", "yes"]] if hide else [])])
        for p in pins:
            if p[0] not in (0, unit):
                continue
            number, pname = p[1], p[2]
            key = number if number in nets else pname if pname in nets else None
            inst.append(["pin", Q(number), ["uuid", Q(uid(self.name, ref, "pin", number))]])
            if key is None:
                continue
            used.add(key)
            self._connect(ref, sx + p[3], sy - p[4], p[5], nets[key])
        inst.append(["instances", ["project", Q(self.project),
                                   ["path", Q(f"/{self.root_uuid}/{self.sheet_uuid}" if self.sheet_uuid else f"/{self.root_uuid}"),
                                    ["reference", Q(ref)], ["unit", str(unit)]]]])
        self.items.append(inst)
        missing = set(nets) - used
        if missing:
            raise SystemExit(f"{ref} ({name}): no pin {sorted(missing)}")
        self.parts.append(ref)

    def _connect(self, ref, px, py, angle, net):
        """A 2.54 mm wire out of the pin, with a no-connect, a power symbol or a global label at its end."""
        dx, dy = {0: (-1, 0), 180: (1, 0), 90: (0, 1), 270: (0, -1)}[angle]
        ex, ey = px + dx * GRID, py + dy * GRID
        if net == "NC":
            self.items.append(["no_connect", ["at", f"{px:g}", f"{py:g}"], ["uuid", Q(uid(self.name, ref, px, py, "nc"))]])
            return
        self.items.append(["wire", ["pts", ["xy", f"{px:g}", f"{py:g}"], ["xy", f"{ex:g}", f"{ey:g}"]],
                           ["stroke", ["width", "0"], ["type", "default"]], ["uuid", Q(uid(self.name, ref, px, py, "w"))]])
        if net in POWER:
            lib, name = POWER[net]
            self._symbol(lib, name)
            rot = 0
            self.items.append(["symbol", ["lib_id", Q(f"{lib}:{name}")], ["at", f"{ex:g}", f"{ey:g}", str(rot)], ["unit", "1"],
                               ["exclude_from_sim", "no"], ["in_bom", "yes"], ["on_board", "yes"], ["dnp", "no"],
                               ["uuid", Q(uid(self.name, ref, px, py, "pwr"))],
                               ["property", Q("Reference"), Q("#PWR"), ["at", f"{ex:g}", f"{ey:g}", "0"],
                                ["effects", ["font", ["size", "1.27", "1.27"]], ["hide", "yes"]]],
                               ["property", Q("Value"), Q(net), ["at", f"{ex:g}", f"{ey + (3.81 if net == 'GND' else -3.81):g}", "0"],
                                ["effects", ["font", ["size", "1.27", "1.27"]]]],
                               ["pin", Q("1"), ["uuid", Q(uid(self.name, ref, px, py, "pwrpin"))]],
                               ["instances", ["project", Q(self.project),
                                              ["path", Q(f"/{self.root_uuid}/{self.sheet_uuid}"),
                                               ["reference", Q(f"#PWR{uid(self.name, ref, px, py)[:6]}")], ["unit", "1"]]]]])
            return
        label_angle = {(-1, 0): 180, (1, 0): 0, (0, 1): 270, (0, -1): 90}[(dx, dy)]
        self.items.append(["global_label", Q(net), ["shape", "bidirectional"], ["at", f"{ex:g}", f"{ey:g}", str(label_angle)],
                           ["fields_autoplaced", "yes"], ["effects", ["font", ["size", "1.27", "1.27"]]],
                           ["uuid", Q(uid(self.name, ref, px, py, "lbl"))],
                           ["property", Q("Intersheetrefs"), Q("${INTERSHEET_REFS}"), ["at", "0", "0", "0"],
                            ["effects", ["font", ["size", "1.27", "1.27"]], ["hide", "yes"]]]])

    def text(self, x, y, s, size=2.54):
        self.items.append(["text", Q(s), ["exclude_from_sim", "no"], ["at", f"{x:g}", f"{y:g}", "0"],
                           ["effects", ["font", ["size", f"{size:g}", f"{size:g}"]], ["justify", "left", "bottom"]],
                           ["uuid", Q(uid(self.name, "text", x, y, s[:12]))]])

    def write(self, path, sheets=()):
        body = ["kicad_sch", ["version", "20260101"], ["generator", Q("kicadgen")], ["generator_version", Q("10.0")],
                ["uuid", Q(self.sheet_uuid or self.root_uuid)], ["paper", Q(self.paper)],
                ["title_block", ["title", Q(self.title or self.name)]],
                ["lib_symbols"] + list(self.libsyms.values())] + self.items + list(sheets) + \
               ([["sheet_instances", ["path", Q("/"), ["page", Q("1")]]]] if not self.sheet_uuid else []) + [["embedded_fonts", "no"]]
        Path(path).write_text(dump(body) + "\n")


POWER = {"GND": ("power", "GND"), "+3V3": ("power", "+3V3"), "+5V": ("power", "+5V"), "+1V2": ("power", "+1V2"),
         "VBUS": ("power", "VBUS")}
custom_symbol_cache = {}


def write_root(path, project, root_uuid, title, sheets):
    """The root schematic: one sheet symbol per (name, file) in `sheets`."""
    root = Sheet(project, "root", root_uuid, None, paper="A4", title=title)
    blocks = []
    for i, (name, file, sheet_uuid) in enumerate(sheets):
        x, y = 30 + (i % 4) * 60, 40 + (i // 4) * 40
        blocks.append(["sheet", ["at", str(x), str(y)], ["size", "45", "20"], ["exclude_from_sim", "no"], ["in_bom", "yes"],
                       ["on_board", "yes"], ["dnp", "no"], ["fields_autoplaced", "yes"],
                       ["stroke", ["width", "0.1524"], ["type", "solid"]], ["fill", ["color", "0", "0", "0", "0.0000"]],
                       ["uuid", Q(sheet_uuid)],
                       ["property", Q("Sheetname"), Q(name), ["at", str(x), f"{y - 0.7:g}", "0"],
                        ["effects", ["font", ["size", "1.27", "1.27"]], ["justify", "left", "bottom"]]],
                       ["property", Q("Sheetfile"), Q(file), ["at", str(x), f"{y + 20.6:g}", "0"],
                        ["effects", ["font", ["size", "1.27", "1.27"]], ["justify", "left", "top"]]],
                       ["instances", ["project", Q(project), ["path", Q(f"/{root_uuid}"), ["page", Q(str(i + 2))]]]]])
    root.write(path, blocks)


def write_symbol_lib(path, symbols):
    """A symbol library of the symbols made here (named `lib:name`; the library holds `name`)."""
    syms = [[s[0], Q(s[1].split(":")[-1])] + s[2:] for s in symbols]
    Path(path).write_text(dump(["kicad_symbol_lib", ["version", "20251024"], ["generator", Q("kicadgen")],
                                ["generator_version", Q("10.0")]] + syms) + "\n")
