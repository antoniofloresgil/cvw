#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""SystemVerilog model of the test board, generated from the KiCad schematic's netlist.

    gen_board.py [mcu_board.kicad_sch | netlist.xml] [board.sv]

The netlist (kicad-cli's XML export) is the board as drawn.  This script turns it into a module `board`
that wires chip_top (the asic_soc_rv32imc RTL) and the behavioural models in models.sv exactly as the
schematic does, so a simulation exercises the board's wiring, not a description of it:

  - nets joined by a series part (ferrite, fuse, an installed jumper, a resistor between two signal nets)
    become one SystemVerilog net; the other names stay readable as aliases
  - a resistor from a net to a rail or to ground is a pull-up or pull-down (tri1 / tri0)
  - a contact of a switch (SW1, the push buttons, the DIP switch) drives the level of the side that has
    one (a rail, else the stronger pull) onto the other when the test closes it, with `<ref>_pressed` or
    `<ref>_closed[i]`
  - the oscillator, reset supervisor, flash, I2C devices, LED buffer, LEDs and the FT2232's JTAG and UART
    pins are models; connectors, regulators, the ESD diode and the capacitors take no part
  - a part that is none of these stops the script: add it to PARTS or IGNORED when you add it to the board

It also checks the netlist against what the parts need: the supply of every model and of the chip is in
its data-sheet range, J2 follows the Cortex Debug 10-pin pinout, and the potentiometer feeds the ADC.
The result drives a cocotb test (test_board.py).
"""

import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCH = HERE.parent / "mcu_board.kicad_sch"

RAIL_V = {"GND": 0.0, "+3V3": 3.3, "+5V": 5.0, "VBUS": 5.0, "+1V2": 1.2}

# Parts that pass a net through: the fuse, the ferrite bead, the jumpers (installed in the model)
PASS_THROUGH = ("Device:Polyfuse", "Device:FerriteBead_Small")

# Parts without a digital part in the simulation
IGNORED = {
    "Device:C", "Device:R_Potentiometer", "Device:Crystal_GND24", "Connector:USB_C_Receptacle_USB2.0_16P",
    "Connector_Generic:Conn_01x03", "Connector_Generic:Conn_01x04", "Connector_Generic:Conn_02x05_Odd_Even",
    "Connector_Generic:Conn_02x06_Odd_Even", "Power_Protection:USBLC6-2SC6", "Regulator_Linear:AP2112K-3.3",
    "Regulator_Linear:AP2112K-1.2", "Memory_EEPROM:93LCxxB",
}

# lib:part -> (module, {pin function: port}, {pin function: (level, ohms)} internal pulls)
# the port is connected to the pin's net; "supply" pins are checked against (min V, max V)
PARTS = {
    "Oscillator:ASE-xxxMHz": ("osc", {"EN": "en", "OUT": "out"}, {}),
    "Power_Supervisor:MAX811SEUS-T": ("max811", {"VCC": "vcc", "~{MR}": "mr", "~{RESET}": "reset_n"}, {"~{MR}": (1, 52e3)}),
    "74xx:74AHC541": ("ahc541", {"G1": "g1_n", "G2": "g2_n", **{f"A{i}": f"a[{i}]" for i in range(8)},
                                 **{f"Y{i}": f"y[{i}]" for i in range(8)}}, {}),
    "Device:LED": ("led", {"A": "a", "K": "k"}, {}),
    "Interface_USB:FT2232HL": ("ft2232", {**{f"ADBUS{i}": f"adbus{i}" for i in range(5)},
                                          **{f"BDBUS{i}": f"bdbus{i}" for i in range(2)}}, {}),
    "Memory_Flash:W25Q32JVSS": ("w25q32", {"~{CS}": "cs_n", "CLK": "clk", "DI/IO_{0}": "di", "DO/IO_{1}": "do_",
                                           "~{HOLD}/~{RESET}/IO_{3}": "hold_n", "~{WP}/IO_{2}": "wp_n"}, {}),
    "Memory_EEPROM:24LC256": ("eeprom24", {"A0": "a0", "A1": "a1", "A2": "a2", "WP": "wp", "SCL": "scl", "SDA": "sda"}, {}),
    "Sensor_Temperature:TMP102xxDRL": ("tmp102", {"ADD0": "add0", "SCL": "scl", "SDA": "sda"}, {}),
    "Analog_ADC:ADS1115IDGS": ("ads1115", {"ADDR": "addr_pin", "SCL": "scl", "SDA": "sda"}, {}),
    "Analog_DAC:MCP4725xxx-xCH": ("mcp4725", {"A0": "a0", "SCL": "scl", "SDA": "sda"}, {}),
}
SWITCHES = ("Switch:SW_Push", "Switch:SW_DIP_x06")
CHIP = "mcu_board:asic_soc_rv32imc"

# Supply pins: lib:part -> {pin function: (min V, max V)}; ground pins must be on GND
SUPPLY = {
    "Oscillator:ASE-xxxMHz": {"Vdd": (2.97, 3.63), "EN": (2.0, 3.63), "GND": (0, 0)},
    "Power_Supervisor:MAX811SEUS-T": {"VCC": (1.2, 5.5), "GND": (0, 0)},
    "74xx:74AHC541": {"VCC": (2.0, 5.5), "GND": (0, 0)},
    "Memory_Flash:W25Q32JVSS": {"VCC": (2.7, 3.6), "GND": (0, 0)},
    "Memory_EEPROM:24LC256": {"VCC": (2.5, 5.5), "GND": (0, 0)},
    "Sensor_Temperature:TMP102xxDRL": {"V+": (1.4, 3.6), "GND": (0, 0)},
    "Analog_ADC:ADS1115IDGS": {"VDD": (2.0, 5.5), "GND": (0, 0)},
    "Analog_DAC:MCP4725xxx-xCH": {"VDD": (2.7, 5.5), "VSS": (0, 0)},
}
CHIP_SUPPLY = {"iovdd": (3.0, 3.6), "iovdd2": (3.0, 3.6), "vdd": (1.08, 1.32), "vdd2": (1.08, 1.32),
               "vss": (0, 0), "vss2": (0, 0), "iovss": (0, 0), "iovss2": (0, 0)}

# Chip pad (the pin function) -> chip_top port
CHIP_PORTS = {"clk": "clk_PAD", "rst_n": "rst_n_PAD", "uart_rx": "uart_rx_PAD", "uart_tx": "uart_tx_PAD",
              "spi_sck": "spi_sck_PAD", "spi_mosi": "spi_mosi_PAD", "spi_miso": "spi_miso_PAD",
              "spi_cs": "spi_cs_PAD", "tck": "tck_PAD", "tms": "tms_PAD", "tdi": "tdi_PAD", "tdo": "tdo_PAD"}


def ident(name):
    """A SystemVerilog identifier for a net name."""
    s = name.replace("+", "P").replace("-", "_")
    s = re.sub(r"\W", "_", s)
    return "n_" + s if s[0].isdigit() else s


def function(pinfunction, pin):
    """The pin's name without the '_<pin>' suffix KiCad adds to it."""
    if pinfunction is None:
        return pin
    return re.sub(r"_[A-Za-z]?\d+$", "", pinfunction)


def ohms(value):
    m = re.match(r"([\d.]+)\s*([kM]?)", value)
    return float(m.group(1)) * {"": 1, "k": 1e3, "M": 1e6}[m.group(2)]


class Union:
    def __init__(self):
        self.parent = {}

    def find(self, x):
        self.parent.setdefault(x, x)
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def join(self, a, b):
        self.parent[self.find(a)] = self.find(b)


class Netlist:
    def __init__(self, xml):
        root = ET.parse(xml).getroot()
        self.comps = {}                  # ref -> (value, lib:part)
        for c in root.find("components"):
            ls = c.find("libsource")
            self.comps[c.get("ref")] = (c.findtext("value"), f"{ls.get('lib')}:{ls.get('part')}")
        self.pins = {}                   # ref -> {pin: (net, function)}
        for n in root.find("nets"):
            for x in n:
                self.pins.setdefault(x.get("ref"), {})[x.get("pin")] = (n.get("name"), function(x.get("pinfunction"), x.get("pin")))
        self.nets = sorted({net for p in self.pins.values() for net, _ in p.values()})

    def part(self, ref):
        return self.comps[ref][1]

    def net(self, ref, pin):
        return self.pins[ref][pin][0]


def build(nl):
    """Group the nets; returns (groups, errors) with groups: rep name -> dict."""
    errors = []
    uf = Union()
    for n in nl.nets:
        uf.find(n)
    for ref, (value, part) in nl.comps.items():
        if part in PASS_THROUGH or (part == "Connector_Generic:Conn_01x02" and "jumper" in value):
            uf.join(nl.net(ref, "1"), nl.net(ref, "2"))
    rail_of = {}
    for n in nl.nets:
        if n in RAIL_V:
            g = uf.find(n)
            if g in rail_of and RAIL_V[rail_of[g]] != RAIL_V[n]:
                errors.append(f"rails {rail_of[g]} and {n} are joined")
            rail_of.setdefault(g, n)

    resistors = [r for r, (_, part) in nl.comps.items() if part == "Device:R"]
    series = {}                          # net name at a joined resistor's pin -> its ohms
    for r in resistors:                  # a resistor between two signal nets joins them
        a, b = uf.find(nl.net(r, "1")), uf.find(nl.net(r, "2"))
        if a not in rail_of and b not in rail_of:
            uf.join(a, b)
            series[nl.net(r, "1")] = series[nl.net(r, "2")] = ohms(nl.comps[r][0])
    rail_of = {uf.find(n): n for n in nl.nets if n in RAIL_V}

    pulls = {}                           # group -> [(level, ohms, source)]
    for r in resistors:
        a, b = uf.find(nl.net(r, "1")), uf.find(nl.net(r, "2"))
        if (a in rail_of) == (b in rail_of):
            if a in rail_of and a != b:
                errors.append(f"{r} joins rails {rail_of[a]} and {rail_of[b]}")
            continue
        rail, sig = (a, b) if a in rail_of else (b, a)
        pulls.setdefault(sig, []).append((0 if RAIL_V[rail_of[rail]] == 0 else 1, ohms(nl.comps[r][0]), r))
    for ref, (_, part) in nl.comps.items():
        if part in PARTS:
            for pin, (net, func) in nl.pins[ref].items():
                if func in PARTS[part][2]:
                    level, r = PARTS[part][2][func]
                    pulls.setdefault(uf.find(net), []).append((level, r, f"{ref}.{func}"))

    groups = {}
    for n in nl.nets:
        groups.setdefault(uf.find(n), []).append(n)
    return uf, rail_of, pulls, groups, series, errors


def pull_level(pulls, group):
    """The level the strongest pull on the group gives it, or None; ties are an error."""
    ps = sorted(pulls.get(group, []), key=lambda p: p[1])
    if not ps:
        return None
    if len(ps) > 1 and ps[0][0] != ps[1][0] and ps[0][1] == ps[1][1]:
        raise ValueError(f"equal pulls to both levels on {ps}")
    return ps[0][0]


def generate(netlist, out):
    nl = Netlist(netlist)
    uf, rail_of, pulls, groups, series, errors = build(nl)

    for ref, (value, part) in nl.comps.items():
        known = (part in PARTS or part in IGNORED or part in SWITCHES or part == CHIP or part in PASS_THROUGH
                 or part in ("Device:R", "Connector_Generic:Conn_01x02") or ref.startswith(("TP", "H")))
        if not known:
            errors.append(f"{ref} ({part}) has no model: add it to PARTS or IGNORED in gen_board.py")

    # representative names: the net of a chip pin, else a rail, else the first name
    chip_nets = {nl.net("U6", p) for p in nl.pins["U6"]}
    rep = {}
    for g, names in groups.items():
        names = [n for n in names if not n.startswith("unconnected-")]
        if not names:
            continue
        best = ([n for n in names if n in chip_nets and n not in RAIL_V] + [n for n in names if n in RAIL_V] + names)[0]
        rep[g] = best
    rep_of = {n: rep[uf.find(n)] for n in nl.nets if uf.find(n) in rep}

    def net_of(ref, pin):
        n = nl.net(ref, pin)
        return ident(rep_of[n]) if n in rep_of else None

    # supplies in range
    def volts(ref, pin):
        g = uf.find(nl.net(ref, pin))
        return RAIL_V[rail_of[g]] if g in rail_of else None

    for ref, (_, part) in nl.comps.items():
        table = SUPPLY.get(part) or (CHIP_SUPPLY if part == CHIP else None)
        if table:
            for pin, (net, func) in nl.pins[ref].items():
                if func in table:
                    v = volts(ref, pin)
                    lo, hi = table[func]
                    if v is None or not lo <= v <= hi:
                        errors.append(f"{ref} pin {pin} ({func}) is on {net} ({'no rail' if v is None else f'{v} V'}), "
                                      f"it needs {lo}-{hi} V")

    # J2 follows the Cortex Debug 10-pin connector: VTref, TMS, GND, TCK, GND, TDO, key, TDI, GND, nRESET
    jtag = {"2": "tms", "4": "tck", "6": "tdo", "8": "tdi"}
    for pin, func in jtag.items():
        chip_pin = next(p for p, (_, f) in nl.pins["U6"].items() if f == func)
        if nl.pins["J2"][pin][0] not in groups[uf.find(nl.net("U6", chip_pin))]:
            errors.append(f"J2 pin {pin} should be {func.upper()}, it is {nl.pins['J2'][pin][0]}")
    if volts("J2", "1") != 3.3:
        errors.append("J2 pin 1 (VTref) should be on the chip's 3.3 V I/O supply")
    for pin in ("3", "5", "9"):
        if volts("J2", pin) != 0:
            errors.append(f"J2 pin {pin} should be GND")
    mr = next(p for p, (_, f) in nl.pins["U7"].items() if f == "~{MR}")
    if nl.pins["J2"]["10"][0] not in groups[uf.find(nl.net("U7", mr))]:
        errors.append("J2 pin 10 (nRESET) should be the reset supervisor's MR")
    # the potentiometer's wiper feeds the ADS1115's AIN0 and its ends are 3.3 V and ground
    ain0 = next(p for p, (_, f) in nl.pins["U12"].items() if f == "AIN0")
    if nl.net("RV1", "2") not in groups[uf.find(nl.net("U12", ain0))]:
        errors.append("RV1's wiper should feed the ADS1115's AIN0")
    if {volts("RV1", "1"), volts("RV1", "3")} != {0.0, 3.3}:
        errors.append("RV1's ends should be on 3.3 V and GND")
    if errors:
        raise SystemExit("netlist checks failed:\n  " + "\n  ".join(errors))

    # ---------------------------------------------------------------------------------------
    lines = ["// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1",
             "// Generated by gen_board.py from the board's netlist; do not edit.", "`timescale 1ns/1ps", "",
             "module board;"]
    for g, name in sorted(rep.items(), key=lambda kv: kv[1]):
        if g in rail_of:
            lines.append(f"  wire {ident(name)} /*verilator public_flat_rw*/ = 1'b{0 if RAIL_V[rail_of[g]] == 0 else 1};   // {RAIL_V[rail_of[g]]} V")
        else:
            lvl = pull_level(pulls, g)
            kind = {None: "tri", 1: "tri1", 0: "tri0"}[lvl]
            lines.append(f"  {kind} {ident(name)} /*verilator public_flat_rw*/;")
    lines.append("")
    for g, names in sorted(groups.items(), key=lambda kv: kv[1][0]):
        if g in rep:
            for n in sorted(names):
                if n != rep[g] and not n.startswith("unconnected-"):
                    lines.append(f"  wire {ident(n)} /*verilator public_flat_rw*/ = {ident(rep[g])};")
    lines.append("")

    # switches: each contact drives the level of its source side onto the other; where several
    # contacts drive one net, the one with the lowest source impedance wins (a button's series
    # resistor, a strap's pull-up), as in the divider they make on the board
    drivers = {}                         # target group -> [(ohms, level, condition)]
    for ref in sorted(nl.comps):
        value, part = nl.comps[ref]
        if part not in SWITCHES:
            continue
        contacts = ([("1", "2")] if part == "Switch:SW_Push" else [(str(i), str(13 - i)) for i in range(1, 7)])
        state = f"{ref.lower()}_pressed" if part == "Switch:SW_Push" else f"{ref.lower()}_closed"
        lines.append(f"  reg {'' if len(contacts) == 1 else '[5:0] '}{state} /*verilator public_flat_rw*/ = 0;"
                     f"   // {ref}: the test closes it")
        for i, (a, b) in enumerate(contacts):
            ga, gb = uf.find(nl.net(ref, a)), uf.find(nl.net(ref, b))
            if ga in rail_of or gb in rail_of:
                src, dst, dpin = (ga, gb, b) if ga in rail_of else (gb, ga, a)
                level, r = int(RAIL_V[rail_of[src]] != 0), series.get(nl.net(ref, dpin), 0.0)
            else:
                pa, pb = pull_level(pulls, ga), pull_level(pulls, gb)
                if pa is None or pb is None:
                    raise SystemExit(f"{ref}: neither side of contact {a}-{b} has a rail or a pull")
                ra, rb = min(p[1] for p in pulls[ga]), min(p[1] for p in pulls[gb])
                src, dst, level, r = (ga, gb, pa, ra) if ra < rb else (gb, ga, pb, rb)
            drivers.setdefault(dst, []).append((r, level, state if len(contacts) == 1 else f"{state}[{i}]"))
    for dst, ds in drivers.items():
        for r, level, cond in ds:
            stronger = [c for r2, l2, c in ds if l2 != level and r2 < r]
            gate = "".join(f" && !{c}" for c in stronger)
            lines.append(f"  assign {ident(rep[dst])} = ({cond}{gate}) ? 1'b{level} : 1'bz;")
    lines.append("")

    # the chip
    conns = []
    for pin, (net, func) in sorted(nl.pins["U6"].items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 99):
        if func in CHIP_PORTS:
            conns.append(f".{CHIP_PORTS[func]}({ident(rep_of[net])})")
    gpio = {int(f[4:]): ident(rep_of[n]) for p, (n, f) in nl.pins["U6"].items() if re.fullmatch(r"gpio\d", f)}
    conns.append(".gpio_PAD({" + ", ".join(gpio[i] for i in range(7, -1, -1)) + "})")
    lines.append("  chip_top u6(" + ", ".join(conns) + ");")
    lines.append("")

    # models
    for ref in sorted(nl.comps, key=lambda r: (r.rstrip("0123456789"), int(r.lstrip("ABCDEFGHIJKLMNOPQRSTUVWXYZ") or 0))):
        value, part = nl.comps[ref]
        if part not in PARTS:
            continue
        module, ports, _ = PARTS[part]
        vec = {}
        for pin, (net, func) in nl.pins[ref].items():
            if func in ports and net in rep_of:
                port = ports[func]
                m = re.fullmatch(r"(\w+)\[(\d+)\]", port)
                if m:
                    vec.setdefault(m.group(1), {})[int(m.group(2))] = ident(rep_of[net])
                else:
                    vec[port] = ident(rep_of[net])
        args = []
        for port, v in vec.items():
            if isinstance(v, dict):
                v = "{" + ", ".join(v.get(i, "1'bz") for i in range(7, -1, -1)) + "}"
            args.append(f".{port}({v})")
        if module == "led":
            lines.append(f"  wire {ref.lower()}_on /*verilator public_flat_rw*/;")
            args.append(f".on({ref.lower()}_on)")
        lines.append(f"  {module} {ref.lower()}({', '.join(args)});   // {ref} {value}")
    lines.append("endmodule")
    Path(out).write_text("\n".join(lines) + "\n")
    return nl, rep_of


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else SCH
    out = sys.argv[2] if len(sys.argv) > 2 else HERE / "build/board.sv"
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    if src.suffix == ".kicad_sch":
        with tempfile.TemporaryDirectory() as tmp:
            xml = Path(tmp) / "net.xml"
            subprocess.run(["kicad-cli", "sch", "export", "netlist", "--format", "kicadxml", "-o", xml, src],
                           check=True, capture_output=True)
            generate(xml, out)
    else:
        generate(src, out)
    print(f"{out}: {sum(1 for _ in open(out))} lines")


if __name__ == "__main__":
    main()
