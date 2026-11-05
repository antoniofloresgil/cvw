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
    "DESIGN_REPAIR_MAX_SLEW_PCT": 40,
    "GRT_DESIGN_REPAIR_MAX_SLEW_PCT": 30,
    # By default only the typical corner makes the setup checker fatal; fail on a setup violation in any corner.
    "TIMING_VIOLATION_CORNERS": ["*"],
    # Synthesis also reads the IO pad library, and ABC would map buffers to sg13g2_IOPadOut4mA
    "EXTRA_EXCLUDED_CELLS": [f"{lib}_IOPad*"],
}
# The chip's floorplan: the die, the core inside the pad ring (365 um), and the SRAM macros in the top
# corners of the core
DIE = 2400
CORE = (365, DIE - 365)
MACRO_W, MACRO_H = 416.64, 336.46          # RM_IHPSG13_1P_1024x32
HALO = 10
# A macro's halo reaches past the core edge, so that it leaves no strip narrower than the PDN pitch
# (see chip/pdn_cfg.tcl): 5 um from the side and 4.54 um from the top of the core
MACRO_Y = round(CORE[1] - 4.54 - MACRO_H, 2)
LEFT_X, RIGHT_X = CORE[0] + 5, round(CORE[1] - 5 - MACRO_W, 2)
# The instruction trace (TRACE_SUPPORTED) puts its 4 KiB buffer in a second macro
vh = (configdir / "config.vh").read_text()
trace = re.search(r"^localparam logic TRACE_SUPPORTED\s*=\s*1\b", vh, re.M) is not None

if sram:
    macro = "RM_IHPSG13_1P_1024x32_c2_bm_bist"
    # The 4 KiB RAM: the DTIM in the core, or the RAM on the bus in a chip; in a chip with the trace,
    # also the trace buffer (src/debug/etracesink.sv)
    if chip:
        instances = {"soc.uncoregen.uncore.ram.ram.memory.ihp.sram": LEFT_X}
        if trace:
            instances["soc.etracegen.etrace.hart[0].sink.ram.ihp.sram"] = RIGHT_X
    else:
        instances = {"core.lsu.dtim.dtim.ram.ihp.sram": None}
    vdd, gnd = ("VDD", "VSS") if chip else ("VPWR", "VGND")
    # Both processes have the same SRAM macros, under libs.ref/<lib>_sram
    srams = f"pdk_dir::libs.ref/{lib}_sram"
    timing = f"{srams}/lib/{macro}"
    config |= {
        "MACROS": {macro: {
            "gds": [f"{srams}/gds/{macro}.gds"],
            "lef": [f"{srams}/lef/{macro}.lef"],
            "vh": [str(here / f"sram/{macro}_bb.v")],
            "lib": {"*typ*": [f"{timing}_typ_1p20V_25C.lib"], "*fast*": [f"{timing}_fast_1p32V_m55C.lib"],
                    "*slow*": [f"{timing}_slow_1p08V_125C.lib"]},
            # In a chip, the top corners of the core (their pins, on the bottom edge, face the core)
            "instances": {inst: {"location": [x, MACRO_Y] if chip else [100, 100], "orientation": "N"}
                          for inst, x in instances.items()},
        }},
        # A Tcl regular expression of the name as OpenROAD stores it (hart\[0\]; the backslashes do
        # not survive LibreLane's parsing): ".*" for each bracket.  The placement above takes the name
        # as it is and escapes it itself.
        "PDN_MACRO_CONNECTIONS": [c for inst in instances
                                  for c in (f"{inst.replace('[', '.*').replace(']', '.*')} {vdd} {gnd} VDD! VSS!",
                                            f"{inst.replace('[', '.*').replace(']', '.*')} {vdd} {gnd} VDDARRAY! VSS!")],
        "PDN_CFG": str(here / ("chip/pdn_cfg.tcl" if chip else "sram/pdn_cfg.tcl")),
        # Subcells of the macros that Magic must flatten to read their GDS, from the PDK's
        # libs.tech/magic/read_sram_gds.tcl (IHP-Open-PDK PR #863)
        "MAGIC_GDS_FLATGLOB": ["lvsres_*", "*_CELL_SUB", "VIA_M1_*", "VIA_M2_*", "RSC_*", "*_CELL_CORNER"],
        # Magic still reports Cnt.c violations inside the macros; check_drc.py checks the rest
        "ERROR_ON_MAGIC_DRC": False,
    }


# The left edges of the channels without cells under the Metal2 straps (see FP_OBSTRUCTIONS)
CHANNELS = [x for x in (round(365.28 + 49.1 + 75.6 * k, 2) for k in range(100)) if x + 8.6 <= CORE[1]]


def channel_top(x):
    """The top of the strap channel at x: the core top, or the bottom of a macro's halo above it."""
    xs = [LEFT_X] + ([RIGHT_X] if trace else [])
    under = any(m - HALO < x + 8.6 and x < m + MACRO_W + HALO for m in xs)
    return round(MACRO_Y - HALO, 2) if under else CORE[1]


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
        # between the pads (80 um wide, 1760 um per side of the 2.4 mm die): 7 pads on each side
        # (150 um apart), or 9; the JTAG pads sit together at the corner of the east and west sides.
        "PAD_SOUTH": ["clk_pad", "rst_n_pad", "vdd_pad", "vss_pad", "uart_rx_pad", "uart_tx_pad", "iovdd2_pad"],
        "PAD_EAST": ["spi_sck_pad", "spi_mosi_pad", "iovss2_pad", "spi_miso_pad", "spi_cs_pad", "tck_pad", "tms_pad"],
        "PAD_NORTH": gpio[:2] + ["vss2_pad", "vdd2_pad"] + gpio[2:4] + ["iovdd_pad"],
        "PAD_WEST": ["tdi_pad", "tdo_pad"] + gpio[4:] + ["iovss_pad"],
        "FP_SIZING": "absolute",
        # The chip grows from 2.0 mm with the debug port and the trace (one more SRAM macro); 365 um
        # for the pad ring.  (The template's 2.2 mm die left the core of the first chip half empty,
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
        # diodes inserted after detailed routing shorted to them.  Below an SRAM macro they stop at
        # its halo.
        "FP_OBSTRUCTIONS": [[x, CORE[0], round(x + 8.6, 2), channel_top(x)] for x in CHANNELS]
        # The strip between the last channel and the core's right edge, narrower than the pitch, where
        # pdngen puts a thin pair of Metal2 straps of its own (0.35 um, near the edge): an antenna diode
        # placed under them in the 2.0 mm chip left its pin no access, and detailed routing shorted
        # it to VDD (6 shorts, LVS failed).
                           + [[round(CHANNELS[-1] + 8.6, 2), CORE[0], CORE[1], channel_top(CHANNELS[-1])]],
    }
    if lib == "sg13cmos5l":
        config["VERILOG_DEFINES"] = ["SG13CMOS5L"]   # chip_top.sv instantiates the pads of the process
(work / "config.json").write_text(json.dumps(config, indent=2) + "\n")
