#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Build/run the native Wally SBI PMU integration model; no multicore RTL required."""

import argparse
import fcntl
import hashlib
import json
import os
import re
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT / "linux/pmu"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--reuse", action="store_true")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--cycles", type=int, default=1000000000)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if "WALLY" not in os.environ:
        parser.error("Source ./setup.sh first")
    if args.resume and (not args.reuse or args.build_only):
        parser.error("--resume requires --reuse without --build-only")
    if args.cycles <= 0:
        parser.error("--cycles must be positive")
    work = args.work.resolve()
    manifest = json.loads((work / "manifest.json").read_text())
    if manifest["kind"] != "wally-native-single-core-pmu" or manifest["counters"] != 32:
        parser.error("Wrong PMU image configuration")
    for rel, digest in manifest["sha256"].items():
        if sha(work / rel) != digest:
            parser.error(f"Image digest mismatch: {rel}")
    lock = (work / "rtl.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error("PMU model already building/running")
    if not args.reuse:
        subprocess.run(["perl", str(ROOT / "bin/derivgen.pl")], cwd=ROOT, check=True)
    sources = [ROOT / "src/cvw.sv", *sorted(p for p in (ROOT / "src").rglob("*.sv") if p.name != "cvw.sv"), HERE / "pmu_tb.sv", HERE / "sim_main.cpp", HERE / "dpi.cpp", ROOT / "config/deriv/pmu_linux/config.vh", *sorted((ROOT / "config/shared").glob("*.vh"))]
    inputs = {"config": "pmu_linux", "savable": True, "verilator": subprocess.check_output(["verilator", "--version"], text=True).strip(), "sources": {str(p.relative_to(ROOT)): sha(p) for p in sources}}
    build = work / "rtl"
    model_path = build / "model.json"
    exe = build / "Vpmu_tb"
    if args.reuse:
        model = json.loads(model_path.read_text())
        if model["inputs"] != inputs or model["binary_sha256"] != sha(exe):
            parser.error("Model differs from current sources; rebuild")
    else:
        # Headers/config participate in the fingerprint, not compilation units.
        command = ["verilator", "--cc", "--exe", "--build", "--assert", "--savable", "-CFLAGS", "-O3", "-MAKEFLAGS", "OPT_FAST=-O3", "-j", str(args.jobs), "--top-module", "pmu_tb", "--Mdir", str(build), f"-I{ROOT}/config/shared", f"-I{ROOT}/config/deriv/pmu_linux", *[str(p) for p in sources if p.suffix in (".sv", ".cpp")]]
        with (work / "rtl-build.log").open("w") as log:
            subprocess.run(command, cwd=ROOT, check=True, stdout=log, stderr=subprocess.STDOUT)
        model = {"inputs": inputs, "binary_sha256": sha(exe), "command": command}
        model_path.write_text(json.dumps(model, indent=2) + "\n")
    if args.build_only:
        print(f"PMU model ready: {exe}", flush=True)
        return 0
    identity = {"model_sha256": model["binary_sha256"], "images": manifest["sha256"]}
    checkpoint = work / "rtl.checkpoint"
    meta = work / "rtl.checkpoint.json"
    if args.resume:
        if not checkpoint.exists() or json.loads(meta.read_text()) != identity:
            parser.error("Checkpoint differs from current images/model")
    else:
        if checkpoint.exists():
            parser.error("Checkpoint exists; use --resume or a new work directory")
        meta.write_text(json.dumps(identity, indent=2) + "\n")
    command = [str(exe), f"+ram={work / 'ram.memfile'}", f"+rom={work / 'boot.memfile'}", f"+cycles={args.cycles}", f"+checkpoint={checkpoint}", "+interval=5000000"]
    if args.resume:
        command.append(f"+restore={checkpoint}")
    (work / "production-process.json").write_text(json.dumps({"started_unix": time.time(), "command": command, **identity}, indent=2) + "\n")
    print(f"Running PMU integration. Log: {work / 'rtl.log'}", flush=True)
    with (work / "rtl.log").open("a" if args.resume else "w") as log:
        code = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT).returncode
    output = (work / "rtl.log").read_text(errors="replace")
    bad = re.search(r"WALLY_PMU_FAIL|Kernel panic|%Error|%Fatal|Assertion failed", output)
    ok = code == 0 and "WALLY_PMU_PASS perf_event_open_and_perf_stat" in output and not bad
    result = {"verdict": "PASS" if ok else "INCOMPLETE" if code == 75 and not bad else "FAIL", "exit_code": code, **identity, "log_sha256": sha(work / "rtl.log")}
    (work / "rtl-result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(result, flush=True)
    return 0 if ok else code if code else 1


if __name__ == "__main__":
    raise SystemExit(main())
