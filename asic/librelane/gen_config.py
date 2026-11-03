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
if sram:
    macro = "RM_IHPSG13_1P_1024x32_c2_bm_bist"
    # The 4 KiB RAM: the DTIM in the core, or the RAM on the bus in a chip
    inst = "soc.uncoregen.uncore.ram.ram.memory.ihp.sram" if chip else "core.lsu.dtim.dtim.ram.ihp.sram"
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
            "instances": {inst: {"location": [400, 400] if chip else [100, 100], "orientation": "N"}},
        }},
        "PDN_MACRO_CONNECTIONS": [f"{inst} {vdd} {gnd} VDD! VSS!", f"{inst} {vdd} {gnd} VDDARRAY! VSS!"],
        "PDN_CFG": str(here / "sram/pdn_cfg.tcl"),
        # Subcells of the macros that Magic must flatten to read their GDS, from the PDK's
        # libs.tech/magic/read_sram_gds.tcl (IHP-Open-PDK PR #863)
        "MAGIC_GDS_FLATGLOB": ["lvsres_*", "*_CELL_SUB", "VIA_M1_*", "VIA_M2_*", "RSC_*", "*_CELL_CORNER"],
        # Magic still reports Cnt.c violations inside the macros; check_drc.py checks the rest
        "ERROR_ON_MAGIC_DRC": False,
    }
if chip:
    # After IHP's LibreLane template (ihp-sg13-librelane-template, librelane/config.yaml); the pads are the instances of chip_top.sv
    gpio = [f"gpio\\[{i}\\].gpio_pad" for i in range(8)]
    config |= {
        "meta": {"version": 3, "flow": "Chip", "substituting_steps": {"Checker.IllegalOverlap": None}},
        "DESIGN_NAME": "chip_top",
        "CLOCK_PORT": "clk_PAD",
        "CLOCK_NET": "clk_pad/p2c",
        "PNR_SDC_FILE": str(here / "chip/chip_top.sdc"),
        "SIGNOFF_SDC_FILE": str(here / "chip/chip_top.sdc"),
        "VDD_NETS": ["VDD"],
        "GND_NETS": ["VSS"],
        "PAD_SOUTH": ["clk_pad", "rst_n_pad", "vdd_pad", "vss_pad", "uart_rx_pad"],
        "PAD_EAST": ["uart_tx_pad", "spi_sck_pad", "spi_mosi_pad", "spi_miso_pad", "spi_cs_pad"],
        "PAD_NORTH": gpio[:4] + ["iovdd_pad"],
        "PAD_WEST": gpio[4:] + ["iovss_pad"],
        "FP_SIZING": "absolute",
        # The template's 2.2 mm die left the core half empty (49 % standard cell utilization), and
        # its metal too sparse for the density rules (Mx Fil.h, M2.j); 365 um for the pad ring
        "DIE_AREA": [0, 0, 2000, 2000],
        "CORE_AREA": [365, 365, 1635, 1635],
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
    }
    if lib == "sg13cmos5l":
        config["VERILOG_DEFINES"] = ["SG13CMOS5L"]   # chip_top.sv instantiates the pads of the process
(work / "config.json").write_text(json.dumps(config, indent=2) + "\n")
