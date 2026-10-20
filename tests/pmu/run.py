#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Directed CSR/event checks plus OpenSBI device-tree binding consistency."""

import argparse
import json
import os
import runpy
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    if "WALLY" not in os.environ:
        parser.error("Source ./setup.sh first")
    args.work.mkdir(parents=True, exist_ok=True)
    generate = runpy.run_path(str(ROOT / "linux/pmu/events.py"))["generate"]
    assert generate() == (ROOT / "linux/devicetree/wally-pmu.dtsi").read_text()
    for n in [3, 8, 32]:
        assert ("0x00005" in generate(n)) == (n > 25)
    results = []
    for rv in [32, 64]:
        for counters in [3, 8, 32]:
            name = f"csr-rv{rv}-{counters}"
            build = args.work / name
            command = ["verilator", "--binary", "--timing", "--assert", "-j", "2", "--top-module", "csrc_tb", f"-GCOUNTER_COUNT={counters}", "--Mdir", str(build), f"-I{ROOT}/config/shared", f"-I{ROOT}/config/rv{rv}gc", str(ROOT / "src/cvw.sv"), str(ROOT / "tests/pmu/csrc_tb.sv"), str(ROOT / "src/privileged/csrc.sv"), str(ROOT / "src/generic/flop/flopenrc.sv")]
            with (args.work / f"{name}-build.log").open("w") as log:
                subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
            with (args.work / f"{name}-run.log").open("w") as log:
                subprocess.run([str(build / "Vcsrc_tb")], check=True, stdout=log, stderr=subprocess.STDOUT)
            results.append({"case": name, "verdict": "PASS", "command": command})
            (args.work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            print("PASS", name, flush=True)
    # Compile every board's real DTS, so /include/ integration is exercised.
    for dts in sorted((ROOT / "linux/devicetree").glob("*.dts")):
        with (args.work / f"{dts.stem}-dtc.log").open("w") as log:
            subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", str(args.work / (dts.stem + ".dtb")), str(dts)], check=True, stdout=log, stderr=subprocess.STDOUT)
    print("PASS: PMU maps and all board DTBs", flush=True)


if __name__ == "__main__":
    main()
