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
}
(work / "config.json").write_text(json.dumps(config, indent=2) + "\n")
