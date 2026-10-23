#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Verify the shared downstream AHB checker and its negative mutations."""

import argparse
import json
import os
import subprocess
from pathlib import Path


def run(command, log):
    log.with_suffix(".command.json").write_text(json.dumps(list(map(str, command)), indent=2) + "\n")
    with log.open("w") as stream:
        return subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=False).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, required=True)
    args = parser.parse_args()
    if "WALLY" not in os.environ:
        parser.error("Source ./setup.sh first")
    root = Path(os.environ["WALLY"]).resolve()
    tests = root / "tests/multicore"
    work = args.work_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    build = work / "model"
    compile_command = ["verilator", "--binary", "--timing", "--assert", "-j", "2", "--top-module",
                       "downstream_checker_tb", "--Mdir", build, str(tests / "ahb_downstream_checker.sv"),
                       str(tests / "downstream_checker_tb.sv")]
    if run(compile_command, work / "build.log") != 0:
        raise SystemExit(f"Checker fixture build failed; see {work / 'build.log'}")
    executable = build / "Vdownstream_checker_tb"
    if run([executable], work / "positive.log") != 0:
        raise SystemExit(f"Valid downstream transactions failed; see {work / 'positive.log'}")
    for mutation, expected in (("malformed-seq", "Malformed or cross-1KiB sequential beat"),
                               ("write-data", "Write data changed during AHB wait")):
        log = work / f"{mutation}.log"
        status = run([executable, f"+mutation={mutation}"], log)
        if status == 0 or expected not in log.read_text(errors="replace"):
            raise SystemExit(f"Checker did not reject {mutation} as expected; see {log}")
        print(f"PASS: downstream checker rejects {mutation}", flush=True)
    print("PASS: downstream checker accepts legal sequence and rejects both mutations", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
