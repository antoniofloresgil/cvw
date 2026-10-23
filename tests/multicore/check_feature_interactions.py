#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Run a bounded complementary option matrix and emit its coverage report."""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

CASES = [
    {
        "name": "minimal-msi-one-word",
        "target": "cache",
        "args": ["--private-dcache", "--no-private-icache", "--cache-words", "32",
                 "--cache-line-words", "1", "--icache-words", "64", "--icache-line-words", "1"],
        "covers": ["private-dcache", "minimal-msi", "one-word-lines", "private-i-disabled",
                   "single-home-msi", "local-paths-disabled", "forwarding-disabled", "bursts-disabled"],
    },
    {
        "name": "local-reads-only",
        "target": "cache",
        "args": ["--private-dcache", "--no-private-icache", "--local-dcache-reads", "--no-local-dcache-writes",
                 "--cache-words", "32", "--cache-line-words", "1"],
        "covers": ["local-reads-isolated"],
    },
    {
        "name": "local-writes-only",
        "target": "cache",
        "args": ["--private-dcache", "--no-private-icache", "--no-local-dcache-reads", "--local-dcache-writes",
                 "--cache-words", "32", "--cache-line-words", "1"],
        "covers": ["local-writes-isolated"],
    },
    {
        "name": "mesi-one-home-forwarding",
        "target": "cache",
        "args": ["--private-dcache", "--private-icache", "--mesi", "--cache-to-cache",
                 "--cache-words", "32", "--cache-line-words", "1", "--icache-words", "64",
                 "--icache-line-words", "4"],
        "covers": ["mesi-one-home", "forwarding-with-mesi", "unequal-capacity-d-smaller",
                   "unequal-lines-i-longer", "private-i-enabled"],
    },
    {
        "name": "banked-msi-no-bursts",
        "target": "cache",
        "args": ["--private-dcache", "--private-icache", "--coherence-banks", "2", "--cache-to-cache",
                 "--cache-words", "64", "--cache-line-words", "4", "--icache-words", "32",
                 "--icache-line-words", "1"],
        "covers": ["banked-msi", "banking-without-bursts", "unequal-capacity-i-smaller",
                   "unequal-lines-d-longer", "forwarding-with-banked-msi"],
    },
    {
        "name": "single-home-msi-bursts",
        "target": "cache",
        "args": ["--private-dcache", "--private-icache", "--cache-bursts", "--cache-words", "32",
                 "--cache-line-words", "4", "--icache-words", "32", "--icache-line-words", "1"],
        "covers": ["bursts-isolated-from-banking", "bursts-with-msi", "burst-d-line"],
    },
    {
        "name": "shared-cache-unit",
        "target": "cache",
        "args": ["--shared-cache", "--shared-cache-words", "32"],
        "covers": ["shared-cache-module"],
    },
    {
        "name": "shared-cache-one-hart",
        "target": "soc",
        "cores": 1,
        "args": ["--shared-cache", "--shared-cache-words", "32"],
        "covers": ["shared-cache-one-hart"],
    },
    {
        "name": "shared-cache-two-harts",
        "target": "soc",
        "cores": 2,
        "args": ["--shared-cache", "--shared-cache-words", "32"],
        "covers": ["shared-cache-multiple-harts"],
    },
    {
        "name": "private-options-one-hart-bypass",
        "target": "soc",
        "cores": 1,
        "args": ["--private-dcache", "--private-icache", "--mesi", "--cache-to-cache",
                 "--local-dcache-reads", "--local-dcache-writes", "--cache-words", "32",
                 "--cache-line-words", "1", "--icache-words", "64", "--icache-line-words", "4"],
        "covers": ["private-options-one-hart-bypass"],
    },
]

COVERAGE = {
    "private-dcache": ["minimal-msi-one-word"],
    "shared-cache": ["shared-cache-unit", "shared-cache-one-hart", "shared-cache-two-harts"],
    "private-icache": ["mesi-one-home-forwarding", "banked-msi-no-bursts"],
    "cache-to-cache": ["mesi-one-home-forwarding", "banked-msi-no-bursts"],
    "cache-bursts": ["single-home-msi-bursts"],
    "mesi": ["mesi-one-home-forwarding"],
    "coherence-banks": ["banked-msi-no-bursts"],
    "local-dcache-reads": ["local-reads-only"],
    "local-dcache-writes": ["local-writes-only"],
    "one-word-lines": ["minimal-msi-one-word"],
    "unequal-i-d-capacities-and-lines": ["mesi-one-home-forwarding", "banked-msi-no-bursts"],
    "single-hart-private-bypass": ["private-options-one-hart-bypass"],
    "selected-risky-pair-mesi-forwarding": ["mesi-one-home-forwarding"],
    "selected-risky-pair-banking-bursts": ["banked-msi-no-bursts", "single-home-msi-bursts"],
    "selected-risky-pair-local-path-independence": ["local-reads-only", "local-writes-only"],
}

LIMITS = {
    "unsupported": ["external DMA coherence", "precise CPU delivery of bus HRESP errors"],
    "unverified": ["FPGA multicore timing and boot", "arbitrary hart-count scaling"],
    "uncovered": ["full Cartesian product of all option values", "all option pairs beyond the selected risky pairs",
                  "RV32 variants of this complementary matrix (the existing MSI/CI profiles retain RV32 coverage)"],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, required=True)
    args = parser.parse_args()
    if "WALLY" not in os.environ:
        parser.error("Source ./setup.sh first")
    root = Path(os.environ["WALLY"]).resolve()
    work = args.work_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    report_path = work / "feature-coverage.json"
    report_path.unlink(missing_ok=True)
    source_paths = [root / "tests/multicore/check_feature_interactions.py", root / "tests/multicore/run.py",
                    root / "tests/multicore/msi_tb.sv", root / "tests/multicore/msifabric_tb.sv",
                    root / "tests/multicore/cache_tb.sv", root / "tests/multicore/soc_tb.sv",
                    root / "config/multicore/schema.json", *sorted((root / "src/ebu").glob("*.sv")),
                    root / "src/wally/wallypipelinedsoc.sv"]
    report = {"schema_version": 1, "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
              "verilator": subprocess.check_output(["verilator", "--version"], text=True).strip(),
              "sources": {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in source_paths if path.is_file()},
              "verdict": "RUNNING", "cases": [], "coverage": {}, "limits": LIMITS}
    all_passed = True
    for case in CASES:
        case_work = work / case["name"]
        case_work.mkdir(parents=True, exist_ok=True)
        command = [sys.executable, str(root / "tests/multicore/run.py"), "--skip-deriv", "--focus", case["target"],
                   "--profile", "stress", "--cores", str(case.get("cores", 2)), "--latency", "0",
                   "--work-dir", str(case_work), *case["args"]]
        log = case_work / "run.log"
        started = time.monotonic()
        try:
            with log.open("w") as stream:
                subprocess.run(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT, check=True)
            verdict = "PASS"
            error = None
        except (subprocess.CalledProcessError, OSError) as exc:
            verdict = "FAIL"
            error = str(exc)
            all_passed = False
        output = log.read_text(errors="replace") if log.exists() else ""
        traffic = re.findall(r"^(?:AHB SEQ beats:.*|LOCAL M:.*|WRITE OVERLAP:.*|LOCAL:.*|TRAFFIC:.*|PASS:.*)$",
                             output, flags=re.MULTILINE)
        record = {"name": case["name"], "target": case["target"], "harts": case.get("cores", 2),
                  "options": case["args"], "covers": case["covers"], "command": command,
                  "verdict": verdict, "elapsed_seconds": round(time.monotonic() - started, 2),
                  "log": str(log), "observations": traffic}
        if error:
            record["error"] = error
        report["cases"].append(record)
        print(f"{verdict}: feature interaction {case['name']}", flush=True)

    for feature, case_names in COVERAGE.items():
        results = {case["name"]: case["verdict"] for case in report["cases"]}
        report["coverage"][feature] = {"cases": case_names,
                                       "verdict": "PASS" if all(results.get(name) == "PASS" for name in case_names)
                                       else "FAIL" if any(results.get(name) == "FAIL" for name in case_names)
                                       else "NOT_RUN"}
    report["verdict"] = "PASS" if all_passed else "FAIL"
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"{report['verdict']}: feature interaction coverage; report {report_path}", flush=True)
    return 0 if all_passed else 1


if __name__ == "__main__":
    sys.exit(main())
