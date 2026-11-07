#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Write the LibreLane inputs for one Wally configuration: a top-level wrapper and config.json."""

import argparse
import json
import re
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--wally", type=Path, required=True, help="Repository root ($WALLY)")
parser.add_argument("--config", required=True, help="Wally configuration, e.g. syn_rv32imc")
parser.add_argument("--work", type=Path, required=True, help="Directory to write into")
parser.add_argument("--clock-period", type=float, required=True, help="Clock period in ns")
parser.add_argument("--pdk", default="ihp-sg13g2", choices=["ihp-sg13g2", "ihp-sg13cmos5l"],
                    help="IHP process: SG13G2 (7 metals) or SG13CMOS5L (CMOS only, 5 metals)")
parser.add_argument("--rom", type=Path, help="$readmemh image of rom1p1r, the IROM or BOOTROM (default: chip/boot.mem for asic_soc_ configurations, else none: an empty ROM)")
args = parser.parse_args()

wally = args.wally.resolve()
work = args.work.resolve()
work.mkdir(parents=True, exist_ok=True)
configdir = next((d for d in (wally / "config" / args.config, wally / "config" / "deriv" / args.config) if d.is_dir()), None)
if configdir is None:
    parser.error(f"no configuration {args.config} in config/ or config/deriv/ (run derivgen.pl)")

# wallypipelinedcore takes its configuration as the parameter P, so wrap it with P taken
# from config.vh.  P is declared in the compilation unit, before the module, because the
# port widths use it.  The parameter list ends at the first ") (" and the ports follow it.
core = (wally / "src/wally/wallypipelinedcore.sv").read_text()
header = re.search(r"^module\s+wallypipelinedcore\b(.*?)^\s*\);", core, re.S | re.M).group(1)
ports = header.split(") (", 1)[1].strip("\n")
wrapper = work / "wallypipelinedcorewrapper.sv"
wrapper.write_text('import cvw::*;\n`include "config.vh"\n`include "parameter-defs.vh"\n\n'
                   f"module wallypipelinedcorewrapper (\n{ports}\n);\n"
                   "  wallypipelinedcore #(.P(P)) core(.*);\nendmodule\n")

here = Path(__file__).resolve().parent
# Prefix of the libraries and cells of the process: sg13g2_stdcell, sg13cmos5l_IOPadIn, ...
lib = args.pdk.removeprefix("ihp-")
sources = [wally / "src/cvw.sv"] + sorted(p for p in (wally / "src").rglob("*.sv") if p.name != "cvw.sv")
# asic_soc_ configurations are chips: Wally's SoC in a pad ring (chip/chip_top.sv), with the
# bootloader (chip/boot.S) in the BOOTROM
chip = args.config.startswith("asic_soc_")
if chip and not args.rom:
    args.rom = here / "chip/boot.mem"

# rom1p1r, which holds the IROM or BOOTROM, preloads $WALLY/fpga/src/boot.mem, a path slang does not
# expand (and since LibreLane 3.1 a missing file is an error).  Load the --rom image instead, or
# nothing: an empty ROM reads as zeros and Yosys removes it, as the earlier runs did.
rom = wally / "src/generic/mem/rom1p1r.sv"
romcopy = work / "rom1p1r.sv"
load = f'$readmemh("{args.rom.resolve()}", ROM, 0);' if args.rom else ";"
# Both branches: the one for Verilator (which simulates this copy in chip/test) and the other one
romtext, n = re.subn(r'\$readmemh\(\{[^}]*"[^"]*/fpga/src/boot\.mem"\}, ROM, 0\);', lambda m: load, rom.read_text())
if n != 2:
    sys.exit(f"{rom}: expected two $readmemh of $WALLY/fpga/src/boot.mem, found {n}")
romcopy.write_text(romtext)
sources = [romcopy if p == rom else p for p in sources]

# asic_ configurations put the RAMs that an IHP SRAM macro implements in the macro: sram/ram1p1rwbe.sv
# replaces Wally's ram1p1rwbe, which it uses for every other shape under the name ram1p1rwbe_generic.
sram = args.config.startswith("asic_")
if sram:
    generic = wally / "src/generic/mem/ram1p1rwbe.sv"
    renamed = work / "ram1p1rwbe_generic.sv"
    renamed.write_text(re.sub(r"^module ram1p1rwbe\b", "module ram1p1rwbe_generic", generic.read_text(), count=1, flags=re.M))
    sources = [p for p in sources if p != generic] + [renamed, here / "sram/ram1p1rwbe.sv"]
config = {
    "DESIGN_NAME": "wallypipelinedcorewrapper",
    "VERILOG_FILES": [str(p) for p in sources + [here / "chip/chip_top.sv" if chip else wrapper]],
    "VERILOG_INCLUDE_DIRS": [str(wally / "config/shared"), str(configdir)],
    "USE_SLANG": True,
    "SLANG_ARGUMENTS": ["--std", "1800-2017", "--single-unit", "--ignore-timing", "--ignore-assertions"],
    "CLOCK_PORT": "clk",
    "CLOCK_PERIOD": args.clock_period,
    # LibreLane 3.1 changed the default from AREA 0 to DELAY 4, which on asic_rv32imc adds 31k
    # buffers and 65 % of cell area in synthesis; the earlier runs closed timing with AREA 0
    "SYNTH_STRATEGY": "AREA 0",
    # Also new defaults in 3.1; without them asic_rv32imc gains 1.6 ns in the slow corner at 30 ns
    "SYNTH_ARITH_TREE": False,
    "SYNTH_MUL_BOOTH": False,
    # The resizer repairs with estimated parasitics, and slews grow after detailed routing: with the
    # defaults (20 % and 10 %) syn_rv32imc had 111 slew violations in the slow corner, with these 2.
    # KLayout's DRC (its density and filler rules tile the whole die) used 21 GB with the 20 threads of
    # this machine on the 2.6 mm chip: six keep it well under 20 GB
    "KLAYOUT_DRC_THREADS": 6,
    "DESIGN_REPAIR_MAX_SLEW_PCT": 40,
    "GRT_DESIGN_REPAIR_MAX_SLEW_PCT": 30,
    # By default only the typical corner makes the setup checker fatal; fail on a setup violation in any corner.
    "TIMING_VIOLATION_CORNERS": ["*"],
    # Synthesis also reads the IO pad library, and ABC would map buffers to sg13g2_IOPadOut4mA
    "EXTRA_EXCLUDED_CELLS": [f"{lib}_IOPad*"],
}
# The chip's floorplan: the die, the core inside the pad ring (365 um), and the SRAM macros: the RAM's
# first four banks in a row along the top of the core, the others (a 64 KiB RAM has eight) in a row along
# the bottom, with their pins facing the standard cells.  With a 64 KiB RAM the trace buffer joins the top
# row and the bottom row sits against the right edge: the clock tree puts a buffer next to the clock
# pad, on the south edge, and a row of macros over the whole edge leaves it no room.
HALO = 10
SIZES = {"RM_IHPSG13_1P_1024x32_c2_bm_bist": (416.64, 336.46), "RM_IHPSG13_1P_2048x32_c2_bm_bist": (416.64, 626.7)}
# A macro's halo reaches past the core edge, so that it leaves no strip narrower than the PDN pitch
# (see chip/pdn_cfg.tcl): 5 um from the side and 4.54 um from the top or bottom of the core.  Side
# by side, the halos of two macros touch, for the same reason.
EDGE_X, EDGE_Y = 5, 4.54
vh = (configdir / "config.vh").read_text()


def param(name):
    """A numeric parameter of config.vh (64'h7FFF, 32'd4, 1)."""
    m = re.search(rf"^localparam\b.*\b{name}\s*=\s*(?:\d*'([hdb]))?([0-9A-Fa-f_]+)\s*;", vh, re.M)
    if m is None:
        return 0
    return int(m.group(2).replace("_", ""), {"h": 16, "b": 2}.get(m.group(1), 10))


# The die: 2.6 mm for the 32 KiB RAM (a row of five macros does not fit), 2.92 mm for 64 KiB; a multiple of 8
# um, so that OpenROAD.PadRing gets whole microns between the pads (see PAD_SOUTH below)
RAM_WORDS = (param("UNCORE_RAM_RANGE") + 1) // 4
DIE = 2600 if RAM_WORDS <= 8192 else 2920
CORE = (365, DIE - 365)

# The instruction trace (TRACE_SUPPORTED) puts its buffer in a macro of its own
trace = param("TRACE_SUPPORTED") == 1


def sram_banks(prefix, words):
    """The macros of a RAM of `words` 32-bit words (sram/ram1p1rwbe.sv): instance -> macro.  Magic reads
    the GDS of one kind of macro only (two kinds share subcell names, and it reports 380,000 false
    errors), so the chip uses the 2048 x 32 macro for all its RAMs."""
    if words == 1024:
        return {f"{prefix}.ihp.sram": "RM_IHPSG13_1P_1024x32_c2_bm_bist"}
    return {f"{prefix}.banked.bank[{i}].sram": "RM_IHPSG13_1P_2048x32_c2_bm_bist" for i in range(words // 2048)}


# The macros: instance -> (macro, x, y, orientation)
placed = {}
if sram and chip:
    # The RAM on the bus: four banks in a row along the top of the core, the others in a row along the
    # bottom.  A 32 KiB RAM leaves the bottom row to the trace buffer, in the corner; a 64 KiB RAM puts
    # the trace buffer at the end of the top row and the four other banks against the bottom right.
    banks = list(sram_banks("soc.uncoregen.uncore.ram.ram.memory", RAM_WORDS).items())
    tracebanks = list(sram_banks("soc.etracegen.etrace.hart[0].sink.ram", param("TRACE_RAM_WORDS")).items()) if trace else []
    two_rows = len(banks) > 4
    top_row = banks[:4] + (tracebanks if two_rows else [])
    bottom_row = banks[4:] + ([] if two_rows else tracebanks)
    for row, macros, top in (("top", top_row, True), ("bottom", bottom_row, False)):
        width = sum(SIZES[m][0] + 2 * HALO for _, m in macros) - 2 * HALO + 2 * EDGE_X
        if width > CORE[1] - CORE[0]:
            sys.exit(f"the {len(macros)} macros of the {row} row do not fit in a {DIE} um die")
        x = CORE[0] + EDGE_X if not (two_rows and not top) else CORE[1] - width + EDGE_X
        for inst, macro in macros:
            w, h = SIZES[macro]
            placed[inst] = (macro, round(x, 2), round(CORE[1] - EDGE_Y - h if top else CORE[0] + EDGE_Y, 2),
                            "N" if top else "S")
            x += w + 2 * HALO
elif sram:
    placed["core.lsu.dtim.dtim.ram.ihp.sram"] = ("RM_IHPSG13_1P_1024x32_c2_bm_bist", 100, 100, "N")

if sram:
    vdd, gnd = ("VDD", "VSS") if chip else ("VPWR", "VGND")
    # Both processes have the same SRAM macros, under libs.ref/<lib>_sram
    srams = f"pdk_dir::libs.ref/{lib}_sram"
    macros = {}
    for inst, (macro, x, y, orient) in placed.items():
        timing = f"{srams}/lib/{macro}"
        macros.setdefault(macro, {
            "gds": [f"{srams}/gds/{macro}.gds"],
            "lef": [f"{srams}/lef/{macro}.lef"],
            "vh": [str(here / f"sram/{macro}_bb.v")],
            "lib": {"*typ*": [f"{timing}_typ_1p20V_25C.lib"], "*fast*": [f"{timing}_fast_1p32V_m55C.lib"],
                    "*slow*": [f"{timing}_slow_1p08V_125C.lib"]},
            "instances": {},
        })["instances"][inst] = {"location": [x, y], "orientation": orient}
    config |= {
        "MACROS": macros,
        # A Tcl regular expression of the name as OpenROAD stores it (hart\[0\]; the backslashes do
        # not survive LibreLane's parsing): ".*" for each bracket.  The placement above takes the name
        # as it is and escapes it itself.
        "PDN_MACRO_CONNECTIONS": [f"{inst.replace('[', '.*').replace(']', '.*')} {vdd} {gnd} {power} VSS!"
                                  for inst in placed for power in ("VDD!", "VDDARRAY!")],
        "PDN_CFG": str(here / ("chip/pdn_cfg.tcl" if chip else "sram/pdn_cfg.tcl")),
        # Subcells of the macros that Magic must flatten to read their GDS, from the PDK's
        # libs.tech/magic/read_sram_gds.tcl (IHP-Open-PDK PR #863)
        "MAGIC_GDS_FLATGLOB": ["lvsres_*", "*_CELL_SUB", "VIA_M1_*", "VIA_M2_*", "RSC_*", "*_CELL_CORNER"],
        # Magic still reports Cnt.c violations inside the macros; check_drc.py checks the rest
        "ERROR_ON_MAGIC_DRC": False,
    }


# The left edges of the channels without cells under the Metal2 straps (see FP_OBSTRUCTIONS)
CHANNELS = [x for x in (round(365.28 + 49.1 + 75.6 * k, 2) for k in range(100)) if x + 8.6 <= CORE[1]]


def channel(x0, x1):
    """The obstructions of a channel from x0 to x1: the core's height, less the macros (with their halos) across it."""
    blocked = []
    for macro, x, y, orient in placed.values():
        w, h = SIZES[macro]
        if x - HALO < x1 and x0 < x + w + HALO:
            blocked.append((y - HALO, y + h + HALO))
    rects, bottom = [], CORE[0]
    for lo, hi in sorted(blocked):
        if lo > bottom:
            rects.append([x0, round(bottom, 2), x1, round(lo, 2)])
        bottom = max(bottom, hi)
    if bottom < CORE[1]:
        rects.append([x0, round(bottom, 2), x1, CORE[1]])
    return rects


if chip:
    # After IHP's LibreLane template (ihp-sg13-librelane-template, librelane/config.yaml); the pads are the instances of chip_top.sv
    gpio = [f"gpio\\[{i}\\].gpio_pad" for i in range(8)]
    config |= {
        # IHP's Magic filler instead of the KLayout one, which the template suggests when the density
        # rules fail: it leaves 5 windows short where the KLayout filler leaves 15
        "meta": {"version": 3, "flow": "Chip", "substituting_steps": {"Checker.IllegalOverlap": None,
                                                                      "KLayout.Filler": "Magic.Filler"}},
        "DESIGN_NAME": "chip_top",
        "CLOCK_PORT": "clk_PAD",
        "CLOCK_NET": "clk_pad/p2c",
        "PNR_SDC_FILE": str(here / "chip/chip_top.sdc"),
        "SIGNOFF_SDC_FILE": str(here / "chip/chip_top.sdc"),
        "VDD_NETS": ["VDD"],
        "GND_NETS": ["VSS"],
        # Each power pad has its twin on the opposite side.  OpenROAD.PadRing needs whole microns
        # between the pads (80 um wide, 1960 um per side of the 2.6 mm die): 7 pads on each side
        # (175 um apart); the JTAG pads sit together at the corner of the east and west sides.
        "PAD_SOUTH": ["clk_pad", "rst_n_pad", "vdd_pad", "vss_pad", "uart_rx_pad", "uart_tx_pad", "iovdd2_pad"],
        "PAD_EAST": ["spi_sck_pad", "spi_mosi_pad", "iovss2_pad", "spi_miso_pad", "spi_cs_pad", "tck_pad", "tms_pad"],
        "PAD_NORTH": gpio[:2] + ["vss2_pad", "vdd2_pad"] + gpio[2:4] + ["iovdd_pad"],
        "PAD_WEST": ["tdi_pad", "tdo_pad"] + gpio[4:] + ["iovss_pad"],
        "FP_SIZING": "absolute",
        # The chip grew from 2.0 mm to 2.4 with the debug port and the trace (one more SRAM macro), and
        # to 2.6 with 32 KiB of RAM, whose four macros need it to fit in a row; 365 um for the pad ring.  (The template's 2.2 mm die left the core of the first chip half empty,
        # 49 % standard cell utilization, and its metal too sparse for the density rules.)
        "DIE_AREA": [0, 0, DIE, DIE],
        "CORE_AREA": [CORE[0], CORE[0], CORE[1], CORE[1]],
        "PDN_CORE_RING": True,
        "PDN_CORE_RING_VWIDTH": 15,      # under 30 um, the widest metal without slotting
        "PDN_CORE_RING_HWIDTH": 15,
        "PDN_CORE_RING_VSPACING": 5,
        "PDN_CORE_RING_HSPACING": 5,
        "PDN_CORE_RING_CONNECT_TO_PADS": True,
        "PDN_ENABLE_PINS": False,
        "MAGIC_EXT_UNIQUE": "notopports",  # several power pads per net
        # The PDK has no bondpad cell yet: the one from IHP's template
        "PAD_BONDPAD_NAME": "bondpad_70x70_novias",
        "EXTRA_GDS": [str(here / f"chip/ip/{lib}_bondpad_70x70_novias/gds/bondpad_70x70_novias.gds")],
        "EXTRA_LEFS": [str(here / f"chip/ip/{lib}_bondpad_70x70_novias/lef/bondpad_70x70_novias.lef")],
        "IGNORE_DISCONNECTED_MODULES": ["bondpad_70x70_novias"],
        # Repair antennas after global routing with a 30 % margin (10 % by default), so that few are
        # left for the repair after detailed routing.  (RUN_HEURISTIC_DIODE_INSERTION puts a diode on
        # every sink of a net over 90 um: 40,293 here, and detailed placement failed.)
        "GRT_ANTENNA_REPAIR_MARGIN": 30,
        # Channels without cells under the Metal2 straps of chip/pdn_cfg.tcl (width 2.8, spacing 2,
        # first pair centred 51 and 55.8 um from the row start at 365.28, pitch 75.6), 0.5 um wider
        # than a pair on each side: with cells under them, the straps covered pins and the antenna
        # diodes inserted after detailed routing shorted to them.  They stop at the SRAM macros' halos.
        "FP_OBSTRUCTIONS": [r for x in CHANNELS for r in channel(x, round(x + 8.6, 2))]
        # The strip between the last channel and the core's right edge, narrower than the pitch, where
        # pdngen puts a thin pair of Metal2 straps of its own (0.35 um, near the edge): an antenna diode
        # placed under them in the 2.0 mm chip left its pin no access, and detailed routing shorted
        # it to VDD (6 shorts, LVS failed).
                           + channel(round(CHANNELS[-1] + 8.6, 2), CORE[1]),
    }
    if lib == "sg13cmos5l":
        config["VERILOG_DEFINES"] = ["SG13CMOS5L"]   # chip_top.sv instantiates the pads of the process
(work / "config.json").write_text(json.dumps(config, indent=2) + "\n")
