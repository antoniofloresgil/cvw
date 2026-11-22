#!/usr/bin/env python3
###########################################
# yosys2firrtl.py
#
# Purpose: Write the flattened Yosys netlist of a Wally configuration (write_json) as one CHIRRTL module that gsim
#          reads.  Yosys's own write_firrtl rejects the memories Wally has (byte write enables, many ports) and its
#          output makes gsim stop while sorting the graph, so this emits the netlist directly:
#            - combinational cells as nodes in topological order;
#            - flip-flops as regs whose next value is one connect (enables and synchronous resets become muxes);
#            - each writable memory as cmems with combinational reads, split at the boundaries of its write enables
#              so that a byte-enable write is one when per byte; read-only memories as constants read by a shift.
#          Only one rising-edge clock (the top port `clock`) is accepted; anything else is reported and stops.
#
# Usage:   yosys2firrtl.py netlist.json out.fir [--top gsimtop]
#          The Yosys script ends with: proc; flatten; opt; opt_mem; opt_mem_priority; opt_mem_feedback;
#          memory_bmux2rom; opt_clean; memory_share -nowiden; opt_clean; write_json (memory_collect is left out:
#          it builds a parameter as wide as the whole RAM, beyond Yosys's width limit for a 128 MiB RAM).
#
# A component of the Wally configurable RISC-V project.
#
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
################################################################################################

import argparse
import json
import re
import sys
from collections import defaultdict, deque

KEYWORDS = {
    "circuit", "module", "extmodule", "input", "output", "wire", "reg", "regreset", "node", "inst", "of", "connect",
    "invalidate", "when", "else", "skip", "mem", "cmem", "smem", "mport", "read", "write", "infer", "rdwr", "clock",
    "reset", "flip", "UInt", "SInt", "Clock", "Reset", "AsyncReset", "Analog", "printf", "stop", "assert", "assume",
    "cover", "with", "attach", "is", "invalid", "old", "new", "undefined", "mux", "validif", "public", "layer",
    "define", "probe", "propassign", "type", "const", "intrinsic", "match", "option",
}

COMB = {
    "$not", "$pos", "$neg", "$and", "$or", "$xor", "$xnor", "$reduce_and", "$reduce_or", "$reduce_xor",
    "$reduce_xnor", "$reduce_bool", "$logic_not", "$logic_and", "$logic_or", "$shl", "$sshl", "$shr", "$sshr",
    "$shift", "$shiftx", "$lt", "$le", "$eq", "$ne", "$eqx", "$nex", "$ge", "$gt", "$add", "$sub", "$mul", "$mux",
    "$pmux", "$bmux", "$demux", "$bwmux",
}
FF = {"$dff", "$dffe", "$sdff", "$sdffe", "$sdffce", "$adff", "$adffe"}
IGNORED = {"$meminit", "$meminit_v2", "$scopeinfo"}


def clog2(n):
    return max(0, (n - 1).bit_length())


def pint(v):
    """A Yosys parameter as an integer (binary string with x bits read as 0, or a number)."""
    if isinstance(v, int):
        return v
    v = v.strip()
    if v == "":
        return 0
    if re.fullmatch(r"[01xz]+", v):
        return int(v.replace("x", "0").replace("z", "0"), 2)
    return int(v)


def pbits(v, width):
    """A constant parameter as an integer of `width` bits."""
    if isinstance(v, int):
        return v & ((1 << width) - 1)
    return int(v.replace("x", "0").replace("z", "0") or "0", 2) & ((1 << width) - 1)


def lit(value, width):
    return f"UInt<{width}>(0h{value:x})"


class Emitter:
    def __init__(self, mod, rmw=False):
        self.mod = mod
        self.rmw = rmw
        self.cells = mod["cells"]
        self.lines = []          # statements of the module body
        self.used = set(KEYWORDS)
        self.driver = {}         # bit -> (signal name, offset, signal width)
        self.undriven = 0
        self.tmp = 0
        self.errors = []
        self.warnings = defaultdict(int)

    # names ---------------------------------------------------------------------------------------------------
    def name(self, raw):
        n = re.sub(r"[^A-Za-z0-9_]", "_", raw.lstrip("\\$"))
        n = re.sub(r"__+", "_", n).strip("_") or "n"
        if not re.match(r"[A-Za-z]", n):
            n = "n" + n
        base, i = n, 0
        while n in self.used:
            i += 1
            n = f"{base}_{i}"
        self.used.add(n)
        return n

    def fresh(self, base):
        self.tmp += 1
        return self.name(f"{base}_t{self.tmp}")

    def node(self, base, expr):
        n = self.fresh(base)
        self.lines.append(f"node {n} = {expr}")
        return n

    # signals -------------------------------------------------------------------------------------------------
    def define(self, bits, name):
        for i, b in enumerate(bits):
            if isinstance(b, int):
                self.driver[b] = (name, i, len(bits))

    def sig(self, bits):
        """Expression for a list of bits (LSB first), as a UInt of len(bits)."""
        runs = []   # (kind, name or const value, lo, hi)
        for b in bits:
            if isinstance(b, str):
                v = 1 if b == "1" else 0
                if runs and runs[-1][0] == "c":
                    k, val, lo, hi = runs[-1]
                    runs[-1] = ("c", val | (v << (hi - lo + 1)), lo, hi + 1)
                else:
                    runs.append(("c", v, 0, 0))
                continue
            d = self.driver.get(b)
            if d is None:
                self.undriven += 1
                d = None
                if runs and runs[-1][0] == "c":
                    k, val, lo, hi = runs[-1]
                    runs[-1] = ("c", val, lo, hi + 1)
                else:
                    runs.append(("c", 0, 0, 0))
                continue
            n, off, w = d
            if runs and runs[-1][0] == "s" and runs[-1][1] == n and runs[-1][3] == off - 1:
                runs[-1] = ("s", n, runs[-1][2], off)
            else:
                runs.append(("s", n, off, off))
        parts = []
        for k, v, lo, hi in runs:
            if k == "c":
                parts.append(lit(v, hi - lo + 1))
            elif lo == 0 and hi == self.width_of[v] - 1:
                parts.append(v)
            else:
                parts.append(f"bits({v}, {hi}, {lo})")
        e = parts[0]
        for i, p in enumerate(parts[1:], 1):
            e = f"cat({p}, {e})"
            if i % 32 == 0 and i != len(parts) - 1:
                e = self.node("cat", e)
        return e

    @staticmethod
    def ext(e, w, to, signed):
        if to == w:
            return e
        if to < w:
            return f"bits({e}, {to - 1}, 0)"
        if signed:
            return f"asUInt(pad(asSInt({e}), {to}))"
        return f"pad({e}, {to})"

    # cells ---------------------------------------------------------------------------------------------------
    def operands(self, c):
        p, con = c["parameters"], c["connections"]
        a = self.sig(con["A"]) if "A" in con else None
        b = self.sig(con["B"]) if "B" in con else None
        aw, bw = len(con.get("A", [])), len(con.get("B", []))
        asg, bsg = pint(p.get("A_SIGNED", 0)), pint(p.get("B_SIGNED", 0))
        return a, b, aw, bw, asg, bsg

    def shift_amount(self, b, bw, w):
        """(amount, too_big) for shifting a value of w bits by b: amount has clog2(w) bits at most."""
        k = max(1, clog2(w))
        if bw <= k:
            return b, None
        return f"bits({b}, {k - 1}, 0)", f"orr(bits({b}, {bw - 1}, {k}))"

    def comb(self, cname, c, out):
        t = c["type"]
        con = c["connections"]
        yw = len(con["Y"])
        a, b, aw, bw, asg, bsg = self.operands(c)
        both = asg and bsg
        zero = lit(0, yw)
        if t in ("$not", "$pos", "$neg"):
            x = self.ext(a, aw, yw, asg)
            e = {"$not": f"not({x})", "$pos": x, "$neg": f"bits(sub({zero}, {x}), {yw - 1}, 0)"}[t]
        elif t in ("$and", "$or", "$xor", "$xnor"):
            x, y = self.ext(a, aw, yw, both), self.ext(b, bw, yw, both)
            op = {"$and": "and", "$or": "or", "$xor": "xor", "$xnor": "xor"}[t]
            e = f"{op}({x}, {y})"
            if t == "$xnor":
                e = f"not({e})"
        elif t in ("$add", "$sub", "$mul"):
            x, y = self.ext(a, aw, yw, both), self.ext(b, bw, yw, both)
            e = f"bits({t[1:]}({x}, {y}), {yw - 1}, 0)"
        elif t in ("$reduce_and", "$reduce_or", "$reduce_xor", "$reduce_xnor", "$reduce_bool", "$logic_not"):
            e = {"$reduce_and": f"andr({a})", "$reduce_or": f"orr({a})", "$reduce_bool": f"orr({a})",
                 "$reduce_xor": f"xorr({a})", "$reduce_xnor": f"not(xorr({a}))", "$logic_not": f"not(orr({a}))"}[t]
            e = self.ext(e, 1, yw, False)
        elif t in ("$logic_and", "$logic_or"):
            e = self.ext(f"{t[7:]}(orr({a}), orr({b}))", 1, yw, False)
        elif t in ("$lt", "$le", "$eq", "$ne", "$eqx", "$nex", "$ge", "$gt"):
            w = max(aw, bw)
            x, y = self.ext(a, aw, w, both), self.ext(b, bw, w, both)
            if both and t not in ("$eq", "$ne", "$eqx", "$nex"):
                x, y = f"asSInt({x})", f"asSInt({y})"
            op = {"$lt": "lt", "$le": "leq", "$eq": "eq", "$ne": "neq", "$eqx": "eq", "$nex": "neq",
                  "$ge": "geq", "$gt": "gt"}[t]
            e = self.ext(f"{op}({x}, {y})", 1, yw, False)
        elif t in ("$shl", "$sshl"):
            x = self.ext(a, aw, yw, asg)
            amt, big = self.shift_amount(b, bw, yw)
            e = f"bits(dshl({x}, {amt}), {yw - 1}, 0)"
            if big:
                e = f"mux({big}, {zero}, {e})"
        elif t in ("$shr", "$sshr", "$shift", "$shiftx"):
            w = max(aw, yw)
            x = self.ext(a, aw, w, asg)
            arith = t == "$sshr" and asg
            if t in ("$shift", "$shiftx") and bsg:
                # negative amounts shift left
                neg = f"bits({b}, {bw - 1}, {bw - 1})"
                mag = f"bits(sub({lit(0, bw)}, {b}), {bw - 1}, 0)"
                la, lbig = self.shift_amount(mag, bw, w)
                left = f"bits(dshl({x}, {la}), {w - 1}, 0)"
                if lbig:
                    left = f"mux({lbig}, {lit(0, w)}, {left})"
                ra, rbig = self.shift_amount(b, bw, w)
                right = f"dshr({x}, {ra})"
                if rbig:
                    right = f"mux({rbig}, {lit(0, w)}, {right})"
                e = f"mux({neg}, {left}, {right})"
            else:
                amt, big = self.shift_amount(b, bw, w)
                if arith:
                    e = f"asUInt(dshr(asSInt({x}), {amt}))"
                    fill = f"mux(bits({x}, {w - 1}, {w - 1}), {lit((1 << w) - 1, w)}, {lit(0, w)})"
                else:
                    e = f"dshr({x}, {amt})"
                    fill = lit(0, w)
                if big:
                    e = f"mux({big}, {fill}, {e})"
            e = self.ext(e, w, yw, False)
        elif t == "$mux":
            s = self.sig(con["S"])
            e = f"mux({s}, {b}, {a})"
        elif t == "$bwmux":
            s = self.sig(con["S"])
            e = f"or(and({a}, not({s})), and({b}, {s}))"
        elif t == "$pmux":
            w = pint(c["parameters"]["WIDTH"])
            sb, bb = con["S"], con["B"]
            e = a
            for i in reversed(range(len(sb))):
                e = f"mux({self.sig([sb[i]])}, {self.sig(bb[i * w:(i + 1) * w])}, {e})"
                if i % 8 == 0 and i:
                    e = self.node(out, e)
        elif t == "$bmux":
            w = pint(c["parameters"]["WIDTH"])
            s = self.sig(con["S"])
            amt = f"cat({s}, {lit(0, clog2(w))})" if w > 1 and (w & (w - 1)) == 0 else (
                s if w == 1 else f"mul({s}, {lit(w, max(1, w.bit_length()))})")
            e = f"bits(dshr({a}, {amt}), {w - 1}, 0)"
        elif t == "$demux":
            w = pint(c["parameters"]["WIDTH"])
            s = self.sig(con["S"])
            amt = f"cat({s}, {lit(0, clog2(w))})" if w > 1 and (w & (w - 1)) == 0 else (
                s if w == 1 else f"mul({s}, {lit(w, max(1, w.bit_length()))})")
            e = f"bits(dshl({self.ext(a, aw, yw, False)}, {amt}), {yw - 1}, 0)"
        else:
            raise AssertionError(t)
        self.lines.append(f"node {out} = {e}")

    def ff_next(self, c, q):
        t, p, con = c["type"], c["parameters"], c["connections"]
        w = pint(p["WIDTH"])
        if con["CLK"] != [self.clock_bit] or not pint(p.get("CLK_POLARITY", 1)):
            self.errors.append(f"{c.get('_name')}: {t} not on the rising edge of the top clock")
        d = self.sig(con["D"])

        def act(port, pol):
            s = self.sig(con[port])
            return s if pint(p.get(pol, 1)) else f"not({s})"

        if t in ("$adff", "$adffe"):
            self.warnings["asynchronous reset modelled as synchronous"] += 1
            rst, rv = act("ARST", "ARST_POLARITY"), lit(pbits(p["ARST_VALUE"], w), w)
        elif t.startswith("$sdff"):
            rst, rv = act("SRST", "SRST_POLARITY"), lit(pbits(p["SRST_VALUE"], w), w)
        else:
            rst = None
        en = act("EN", "EN_POLARITY") if t in ("$dffe", "$sdffe", "$sdffce", "$adffe") else None
        if t == "$sdffce":
            e = f"mux({en}, mux({rst}, {rv}, {d}), {q})"
        else:
            e = d
            if en:
                e = f"mux({en}, {e}, {q})"
            if rst:
                e = f"mux({rst}, {rv}, {e})"
        return e

    # memories ------------------------------------------------------------------------------------------------
    def memory_layout(self):
        mems = {}
        for memid, m in self.mod.get("memories", {}).items():
            mems[memid] = {"width": m["width"], "size": m["size"], "offset": m["start_offset"],
                           "rd": [], "wr": [], "init": []}
        for cn, c in self.cells.items():
            t = c["type"]
            if t in ("$memrd", "$memrd_v2", "$memwr", "$memwr_v2", "$meminit", "$meminit_v2"):
                memid = c["parameters"]["MEMID"].lstrip("\\")
                key = memid if memid in mems else "\\" + memid
                if key not in mems:
                    key = next(k for k in mems if k.lstrip("\\") == memid)
                kind = {"rd": "rd", "wr": "wr", "in": "init"}[t[4:6]]
                mems[key][kind].append((cn, c))
        return mems

    def declare_memories(self, mems):
        for memid, m in mems.items():
            w, depth = m["width"], 1 << clog2(m["offset"] + m["size"])
            m["k"] = clog2(m["offset"] + m["size"])
            if not m["wr"]:
                # read-only: a constant indexed by a shift
                words = [0] * depth
                for cn, c in sorted(m["init"], key=lambda x: pint(x[1]["parameters"].get("PRIORITY", 0))):
                    p, con = c["parameters"], c["connections"]
                    addr = pbits("".join(str(b) for b in reversed(con["ADDR"])) if isinstance(con["ADDR"], list)
                                 else p["ADDR"], 64)
                    data = con["DATA"] if "DATA" in con else None
                    nwords = pint(p.get("WORDS", 1))
                    bits = "".join(reversed([str(b) for b in data])) if data else p["DATA"]
                    val = pbits(bits, nwords * w)
                    for i in range(nwords):
                        if 0 <= addr + i < depth:
                            words[addr + i] = (val >> (i * w)) & ((1 << w) - 1)
                value = 0
                for i, x in enumerate(words):
                    value |= x << (i * w)
                m["rom"] = self.name(memid + "_rom")
                self.lines.append(f"node {m['rom']} = {lit(value, w * depth)}")
                continue
            if m["init"]:
                self.warnings["initial contents of a writable memory ignored"] += 1
            # segments: boundaries where any write port's enable bit changes
            cuts = {0, w}
            for cn, c in m["wr"]:
                if c["parameters"].get("WIDE_CONTINUATION") and pint(c["parameters"]["WIDE_CONTINUATION"]):
                    self.errors.append(f"{memid}: wide write port")
                en = c["connections"]["EN"]
                if len(en) != w:
                    self.errors.append(f"{memid}: write port of {len(en)} bits, memory of {w}")
                for i in range(1, w):
                    if en[i] != en[i - 1]:
                        cuts.add(i)
            cuts = sorted(cuts)
            m["segs"] = []
            m["cuts"] = cuts
            base = self.name(memid)
            if self.rmw and len(cuts) > 2:
                # one memory as wide as the words; a partial write reads the word and merges the enabled bits
                self.lines.append(f"cmem {base} : UInt<{w}>[{depth}]")
                m["segs"].append((base, 0, w))
                m["rmw"] = True
                continue
            for lo, hi in zip(cuts, cuts[1:]):
                n = base if len(cuts) == 2 else self.name(f"{base}_{lo}")
                self.lines.append(f"cmem {n} : UInt<{hi - lo}>[{depth}]")
                m["segs"].append((n, lo, hi))

    def index(self, m, addr_bits):
        a = self.sig(addr_bits)
        k, aw = m["k"], len(addr_bits)
        if k == 0:
            return lit(0, 1)
        return self.ext(a, aw, k, False)

    def mem_read(self, m, c, out):
        p, con = c["parameters"], c["connections"]
        if pint(p.get("CLK_ENABLE", 0)):
            self.errors.append(f"{out}: clocked read port (run without memory_dff)")
        w = m["width"]
        if "rom" in m:
            idx = self.index(m, con["ADDR"])
            amt = f"cat({idx}, {lit(0, clog2(w))})" if (w & (w - 1)) == 0 and w > 1 else (
                idx if w == 1 else f"mul({idx}, {lit(w, w.bit_length())})")
            self.lines.append(f"node {out} = bits(dshr({m['rom']}, {amt}), {w - 1}, 0)")
            return
        idx = self.node(out + "_idx", self.index(m, con["ADDR"]))
        parts = []
        for n, lo, hi in m["segs"]:
            port = self.fresh(f"{n}_r")
            self.lines.append(f"infer mport {port} = {n}[{idx}], clock")
            parts.append(port)
        e = parts[0]
        for prt in parts[1:]:
            e = f"cat({prt}, {e})"
        self.lines.append(f"node {out} = {e}")

    def mem_writes(self, mems):
        for memid, m in mems.items():
            if "rom" in m:
                continue
            ports = sorted(m["wr"], key=lambda x: pint(x[1]["parameters"].get("PORTID", 0)))
            for cn, c in ports:
                p, con = c["parameters"], c["connections"]
                if con["CLK"] != [self.clock_bit] or not pint(p.get("CLK_POLARITY", 1)) or \
                        not pint(p.get("CLK_ENABLE", 1)):
                    self.errors.append(f"{memid}: write port not on the rising edge of the top clock")
                idx = self.node(m["segs"][0][0] + "_widx", self.index(m, con["ADDR"]))
                data, en = con["DATA"], con["EN"]
                if m.get("rmw"):
                    n, cuts = m["segs"][0][0], m["cuts"]
                    parts, any_en = [], []
                    for lo, hi in zip(cuts, cuts[1:]):
                        e = en[lo]
                        ones = lit((1 << (hi - lo)) - 1, hi - lo)
                        if e == "1":
                            parts.append(ones)
                            any_en.append(lit(1, 1))
                        elif isinstance(e, str):
                            parts.append(lit(0, hi - lo))
                        else:
                            s = self.sig([e])
                            parts.append(f"mux({s}, {ones}, {lit(0, hi - lo)})")
                            any_en.append(s)
                    if not any_en:
                        continue
                    mask = parts[0]
                    for prt in parts[1:]:
                        mask = f"cat({prt}, {mask})"
                    mask = self.node(n + "_wmask", mask)
                    old = self.fresh(f"{n}_old")
                    self.lines.append(f"infer mport {old} = {n}[{idx}], clock")
                    new = self.node(n + "_wdata",
                                    f"or(and({old}, not({mask})), and({self.sig(data)}, {mask}))")
                    cond = any_en[0]
                    for s in any_en[1:]:
                        cond = f"or({s}, {cond})"
                    port = self.fresh(f"{n}_w")
                    self.lines.append(f"when {cond} :")
                    self.lines.append(f"  write mport {port} = {n}[{idx}], clock")
                    self.lines.append(f"  connect {port}, {new}")
                    continue
                for n, lo, hi in m["segs"]:
                    e = en[lo]
                    if e == "0" or e == "x":
                        continue
                    port = self.fresh(f"{n}_w")
                    ind = "" if e == "1" else "  "
                    if e != "1":
                        self.lines.append(f"when {self.sig([e])} :")
                    self.lines.append(f"{ind}write mport {port} = {n}[{idx}], clock")
                    self.lines.append(f"{ind}connect {port}, {self.sig(data[lo:hi])}")

    # whole module --------------------------------------------------------------------------------------------
    def run(self, top):
        mod = self.mod
        self.width_of = {}
        header = []
        ports = mod["ports"]
        if "clock" not in ports:
            sys.exit("the top module needs an input port `clock`")
        self.clock_bit = ports["clock"]["bits"][0]
        for pn in ports:
            self.used.add(pn)
        for pn, pt in ports.items():
            w = len(pt["bits"])
            if pt["direction"] == "input":
                ty = "Clock" if pn == "clock" else f"UInt<{w}>"
                header.append(f"input {pn} : {ty}")
                if pn != "clock":
                    self.define(pt["bits"], pn)
                    self.width_of[pn] = w
            else:
                header.append(f"output {pn} : UInt<{w}>")

        # preferred names: a visible netname with exactly the output bits
        names = {}
        for nn, net in sorted(mod["netnames"].items(), key=lambda x: (x[1].get("hide_name", 0), len(x[0]))):
            names.setdefault(tuple(net["bits"]), nn)

        mems = self.memory_layout()
        memof = {}
        for memid, m in mems.items():
            for cn, c in m["rd"]:
                memof[cn] = memid

        outs = {}       # cell -> (name, bits)
        regs = []
        for cn, c in self.cells.items():
            c["_name"] = cn
            t = c["type"]
            if t in IGNORED or t.startswith("$memwr"):
                continue
            if t not in COMB and t not in FF and not t.startswith("$memrd"):
                self.errors.append(f"{cn}: cell type {t} not supported")
                continue
            port = "Q" if t in FF else ("DATA" if t.startswith("$memrd") else "Y")
            bits = c["connections"][port]
            n = self.name(names.get(tuple(bits), cn))
            outs[cn] = (n, bits)
            self.define(bits, n)
            self.width_of[n] = len(bits)
            if t in FF:
                regs.append(cn)

        # topological order of the combinational cells and read ports
        bitcell = {}
        for cn, (n, bits) in outs.items():
            if self.cells[cn]["type"] not in FF:
                for b in bits:
                    if isinstance(b, int):
                        bitcell[b] = cn
        deps = defaultdict(set)
        users = defaultdict(set)
        comb = [cn for cn in outs if self.cells[cn]["type"] not in FF]
        for cn in comb:
            c = self.cells[cn]
            for pn, bits in c["connections"].items():
                if c["port_directions"].get(pn) != "input":
                    continue
                for b in bits:
                    d = bitcell.get(b) if isinstance(b, int) else None
                    if d and d != cn:
                        deps[cn].add(d)
                        users[d].add(cn)
        indeg = {cn: len(deps[cn]) for cn in comb}
        ready = deque(sorted(cn for cn in comb if indeg[cn] == 0))
        order = []
        while ready:
            cn = ready.popleft()
            order.append(cn)
            for u in users[cn]:
                indeg[u] -= 1
                if indeg[u] == 0:
                    ready.append(u)
        if len(order) != len(comb):
            stuck = [cn for cn in comb if indeg[cn] > 0][:20]
            self.errors.append(f"combinational loop through {len(comb) - len(order)} cells, e.g. {stuck}")

        # registers, memories, combinational logic, next states, memory writes, outputs
        for cn in regs:
            n, bits = outs[cn]
            self.lines.append(f"reg {n} : UInt<{len(bits)}>, clock")
        self.declare_memories(mems)
        for cn in order:
            n, bits = outs[cn]
            c = self.cells[cn]
            if c["type"].startswith("$memrd"):
                self.mem_read(mems[memof[cn]], c, n)
            else:
                self.comb(cn, c, n)
        for cn in regs:
            n, bits = outs[cn]
            nxt = self.ff_next(self.cells[cn], n)
            self.lines.append(f"connect {n}, {nxt}")
        self.mem_writes(mems)
        for pn, pt in ports.items():
            if pt["direction"] == "output":
                self.lines.append(f"connect {pn}, {self.sig(pt['bits'])}")

        out = ["FIRRTL version 4.0.0", f"circuit {top} :", f"  module {top} :"]
        out += ["    " + h for h in header]
        out.append("")
        out += ["    " + s for s in self.lines]
        return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("json")
    ap.add_argument("fir")
    ap.add_argument("--top", default="gsimtop")
    ap.add_argument("--split", action="store_true",
                    help="split memories with partial writes into one memory per enable segment "
                         "(default: one wide memory written by read-modify-write)")
    a = ap.parse_args()
    with open(a.json) as f:
        d = json.load(f)
    if a.top not in d["modules"]:
        sys.exit(f"module {a.top} not in {a.json} (flatten first)")
    em = Emitter(d["modules"][a.top], rmw=not a.split)
    text = em.run(a.top)
    for k, v in em.warnings.items():
        print(f"warning: {k} ({v})", file=sys.stderr)
    if em.undriven:
        print(f"warning: {em.undriven} undriven bits read as 0", file=sys.stderr)
    if em.errors:
        for e in em.errors[:50]:
            print("error: " + e, file=sys.stderr)
        sys.exit(f"{len(em.errors)} errors")
    with open(a.fir, "w") as f:
        f.write(text)
    print(f"{a.fir}: {len(em.lines)} statements", file=sys.stderr)


if __name__ == "__main__":
    main()
