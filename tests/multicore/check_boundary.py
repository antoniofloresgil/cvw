#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Exercise real Wally EBU/ahbinterface endpoints and the buffered-port contract."""

import argparse
import hashlib
import json
import os
import resource
import subprocess
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--banks", type=int, choices=[1, 2], nargs="+", default=[1, 2])
    parser.add_argument("--cores", type=int, choices=[2, 3], nargs="+", default=[2, 3])
    parser.add_argument("--latency", type=int, choices=[0, 3], nargs="+", default=[0, 3])
    parser.add_argument("--configs", choices=["rv32gc", "rv64gc"], nargs="+", default=["rv32gc", "rv64gc"])
    parser.add_argument("--negative", action="store_true", help="Also require six deliberately broken endpoint cases to fail with named assertions")
    parser.add_argument("--work-dir", type=Path, required=True)
    args = parser.parse_args()
    if "WALLY" not in os.environ:
        parser.error("Source ./setup.sh first")
    if args.negative and not (1 in args.banks and 2 in args.cores and 3 in args.latency and "rv64gc" in args.configs):
        parser.error("Negative cases require rv64gc, two harts, one home and latency 3")
    # Expected assertion failures should not leave large simulator core dumps.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    root = Path(os.environ["WALLY"]).resolve()
    work = args.work_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    summary = work / "results.json"
    summary.unlink(missing_ok=True)
    sources = [root / "src/cvw.sv", root / "tests/multicore/adapter_tb.sv",
               *sorted(p for p in (root / "src").rglob("*.sv") if p.name != "cvw.sv")]
    inputs = sources + [Path(__file__).resolve(), *sorted((root / "config/shared").glob("*.vh")),
                       *(root / "config" / cfg / "config.vh" for cfg in args.configs)]
    manifest = {"source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
                "verilator": subprocess.check_output(["verilator", "--version"], text=True).strip(),
                "sources": {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}, "results": []}
    try:
        for cfg in args.configs:
            for cores in args.cores:
                for banks in args.banks:
                    for latency in args.latency:
                        name = f"{cfg}-{cores}h-{banks}b-w{latency}"
                        casework = work / name
                        casework.mkdir(exist_ok=True)
                        command = ["verilator", "--binary", "--timing", "--assert", "--output-split", "0", "-j", "2",
                                   "--top-module", "adapter_tb", f"-GNCORES={cores}", f"-GBANKS={banks}", f"-GLATENCY={latency}",
                                   "--Mdir", str(casework / "model"), f"-I{root}/config/shared", f"-I{root}/config/{cfg}", *map(str, sources)]
                        (casework / "build-command.json").write_text(json.dumps(command, indent=2) + "\n")
                        with (casework / "build.log").open("w") as stream:
                            subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=True)
                        executable = casework / "model/Vadapter_tb"
                        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=60)
                        (casework / "run.log").write_text(result.stdout + result.stderr)
                        if result.returncode or "PASS:" not in result.stdout:
                            raise RuntimeError(f"{name}: see {casework / 'run.log'}")
                        manifest["results"].append({"case": name, "verdict": "PASS"})
                        print(result.stdout.splitlines()[0], flush=True)
                        if args.negative and (cfg, cores, banks, latency) == ("rv64gc", 2, 1, 3):
                            for plusarg, message in (("BAD_DATA", "write data changed before reply"), ("BAD_STRB", "write strobes changed before reply"),
                                                     ("BAD_OP", "LR/SC direction mismatch"), ("BAD_SC", "SC result changed outside SC completion"),
                                                     ("BAD_AMO_ADDR", "AMO write does not match locked read"), ("BAD_ERROR", "missing first ERROR phase")):
                                result = subprocess.run([str(executable), f"+{plusarg}"], capture_output=True, text=True, timeout=60)
                                (casework / f"{plusarg}.log").write_text(result.stdout + result.stderr)
                                if not result.returncode or f"corebus contract: {message}" not in result.stdout + result.stderr:
                                    raise RuntimeError(f"{plusarg}: missing expected assertion; see {casework}")
                                manifest["results"].append({"case": plusarg, "verdict": "PASS", "expected_failure": message})
                                print(f"PASS: {plusarg} detected by contract assertion", flush=True)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, RuntimeError) as error:
        manifest["verdict"] = "FAIL"
        manifest["error"] = str(error)
        summary.write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"FAIL: boundary matrix; see {work}: {error}", file=sys.stderr)
        return 1
    manifest["verdict"] = "PASS"
    summary.write_text(json.dumps(manifest, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
