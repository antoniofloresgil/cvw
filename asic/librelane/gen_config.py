#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Write the LibreLane inputs for one Wally configuration: a top-level wrapper and config.json."""

import argparse
import json
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--wally", type=Path, required=True, help="Repository root ($WALLY)")
parser.add_argument("--config", required=True, help="Wally configuration, e.g. syn_rv32imc")
parser.add_argument("--work", type=Path, required=True, help="Directory to write into")
parser.add_argument("--clock-period", type=float, required=True, help="Clock period in ns")
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

sources = [wally / "src/cvw.sv"] + sorted(p for p in (wally / "src").rglob("*.sv") if p.name != "cvw.sv")

# asic_ configurations put the RAMs that an IHP SRAM macro implements in the macro: sram/ram1p1rwbe.sv
# replaces Wally's ram1p1rwbe, which it uses for every other shape under the name ram1p1rwbe_generic.
sram = args.config.startswith("asic_")
if sram:
    here = Path(__file__).resolve().parent
    generic = wally / "src/generic/mem/ram1p1rwbe.sv"
    renamed = work / "ram1p1rwbe_generic.sv"
    renamed.write_text(re.sub(r"^module ram1p1rwbe\b", "module ram1p1rwbe_generic", generic.read_text(), count=1, flags=re.M))
    sources = [p for p in sources if p != generic] + [renamed, here / "sram/ram1p1rwbe.sv"]
config = {
    "DESIGN_NAME": "wallypipelinedcorewrapper",
    "VERILOG_FILES": [str(p) for p in sources + [wrapper]],
    "VERILOG_INCLUDE_DIRS": [str(wally / "config/shared"), str(configdir)],
    "USE_SLANG": True,
    "SLANG_ARGUMENTS": ["--std", "1800-2017", "--single-unit", "--ignore-timing", "--ignore-assertions"],
    "CLOCK_PORT": "clk",
    "CLOCK_PERIOD": args.clock_period,
    # The resizer repairs with estimated parasitics, and slews grow after detailed routing: with the
    # defaults (20 % and 10 %) syn_rv32imc had 111 slew violations in the slow corner, with these 2.
    "DESIGN_REPAIR_MAX_SLEW_PCT": 40,
    "GRT_DESIGN_REPAIR_MAX_SLEW_PCT": 30,
    # By default only the typical corner makes the setup checker fatal; fail on a setup violation in any corner.
    "TIMING_VIOLATION_CORNERS": ["*"],
}
if sram:
    macro = "RM_IHPSG13_1P_1024x32_c2_bm_bist"
    DTIM_INSTANCE = "core.lsu.dtim.dtim.ram.ihp.sram"
    lib = "pdk_dir::libs.ref/sg13g2_sram/lib/" + macro
    config |= {
        "MACROS": {macro: {
            "gds": [f"pdk_dir::libs.ref/sg13g2_sram/gds/{macro}.gds"],
            "lef": [f"pdk_dir::libs.ref/sg13g2_sram/lef/{macro}.lef"],
            "vh": [str(here / f"sram/{macro}_bb.v")],
            "lib": {"*typ*": [f"{lib}_typ_1p20V_25C.lib"], "*fast*": [f"{lib}_fast_1p32V_m55C.lib"],
                    "*slow*": [f"{lib}_slow_1p08V_125C.lib"]},
            "instances": {DTIM_INSTANCE: {"location": [100, 100], "orientation": "N"}},
        }},
        "PDN_MACRO_CONNECTIONS": [f"{DTIM_INSTANCE} VPWR VGND VDD! VSS!", f"{DTIM_INSTANCE} VPWR VGND VDDARRAY! VSS!"],
        "PDN_CFG": str(here / "sram/pdn_cfg.tcl"),
        # The full KLayout deck reports violations inside the IHP SRAM macros; check_drc.py checks the rest
        "ERROR_ON_KLAYOUT_DRC": False,
        # So does Magic (millions): the SRAM rule exceptions came with IHP-Open-PDK PR #863, after the
        # PDK version that LibreLane 3.0.17 pins
        "RUN_MAGIC_DRC": False,
    }
(work / "config.json").write_text(json.dumps(config, indent=2) + "\n")
