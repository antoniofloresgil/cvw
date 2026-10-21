#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Compare single-hart peripherals with upstream and the one-hart SMP engines."""

import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path


def check_atomic_walker(root, work):
    """Drive a real AMO translation and observe the selected bus operation."""
    atomic = work / "atomic-walker"
    atomic.mkdir(exist_ok=True)
    source = root / "tests/coverage/amoADUpdate.S"
    assembly, obj, elf = [atomic / f"amoADUpdate.{ext}" for ext in ("s", "o", "elf")]
    commands = [
        ["riscv64-unknown-elf-gcc", "-E", f"-I{root}/tests/coverage", str(source), "-o", str(assembly)],
        ["riscv64-unknown-elf-as", "-march=rv64ia_zicsr_zifencei", "-mabi=lp64", str(assembly), "-o", str(obj)],
        ["riscv64-unknown-elf-gcc", "-g", "-mcmodel=medany", "-nostdlib", "-nostartfiles", f"-T{root}/examples/link/link.ld", str(obj), "-o", str(elf)],
    ]
    (atomic / "elf-commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    for command in commands:
        subprocess.run(command, check=True)
    # Keep the normal top name and its existing absolute verification probes.
    bench = (root / "testbench/testbench.sv").read_text()
    monitor = (root / "tests/multicore/atomic_walker_monitor.svh").read_text()
    index = bench.rindex("endmodule")
    fixture = atomic / "testbench.sv"
    fixture.write_text(bench[:index] + monitor + bench[index:])
    dpi = atomic / "wrapper.c"
    dpi.write_text((root / "sim/verilator/wrapper.c").read_text())
    # The official testbench requires both caches when virtual memory is enabled.
    name, include = "cached", root / "config/rv64gc"
    build = atomic / name / "model"
    build.mkdir(parents=True, exist_ok=True)
    command = ["verilator", "--binary", "--timing", "--assert", "--relative-includes", "-j", "2", "--top-module", "testbench",
               "--Mdir", str(build), f"-I{include}", f"-I{root}/config/shared", f"-I{root}/testbench", str(root / "src/cvw.sv"),
               str(fixture), str(dpi), *map(str, sorted((root / "testbench/common").glob("*.sv"))),
               *map(str, sorted(p for p in (root / "src").rglob("*.sv") if p.name != "cvw.sv"))]
    (atomic / f"{name}-command.json").write_text(json.dumps(command, indent=2) + "\n")
    with (atomic / f"{name}-build.log").open("w") as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    result = subprocess.run([str(build / "Vtestbench"), f"+ElfFile={elf}", "+TEST=atomic-walker", f"+sim_log_prefix={atomic}/{name}"],
                            cwd=root / "sim/verilator", stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (atomic / f"{name}-run.log").write_text(result.stdout)
    if result.returncode or "SUCCESS! All tests ran without failures." not in result.stdout or "PASS: observed" not in result.stdout:
        raise SystemExit(f"FAIL atomic walker/{name}: see {atomic / f'{name}-run.log'}")
    print(f"PASS: single-hart AMO/PTE A/D updates and LR/SC, {name} LSU, overlap observed", flush=True)
    return {"test": "atomic-walker", "config": "rv64gc", "uncacheable_data": True, "verdict": "PASS"}


def check_clocks(root, work):
    results = []
    for config in ("rv32i", "rv64gc"):
        build = work / f"clocks-{config}"
        command = ["verilator", "--binary", "--timing", "--assert", "-j", "2", "--top-module", "soc_clock_tb",
                   "--Mdir", str(build), f"-I{root}/config/shared", f"-I{root}/config/{config}", str(root / "src/cvw.sv"),
                   str(root / "tests/multicore/soc_clock_tb.sv"), str(root / "tests/multicore/dpi.cpp"),
                   *map(str, sorted(p for p in (root / "src").rglob("*.sv") if p.name != "cvw.sv"))]
        (work / f"clocks-{config}-command.json").write_text(json.dumps(command, indent=2) + "\n")
        with (work / f"clocks-{config}-build.log").open("w") as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        result = subprocess.run([str(build / "Vsoc_clock_tb")], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (work / f"clocks-{config}-run.log").write_text(result.stdout)
        if result.returncode or "PASS:" not in result.stdout:
            raise SystemExit(f"FAIL clocks/{config}: see {work / f'clocks-{config}-run.log'}")
        print(result.stdout.splitlines()[0], flush=True)
        results.append({"test": "soc-clocks", "config": config, "verdict": "PASS"})
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream-ref", default="main", help="Local Git reference; recorded as an immutable commit")
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--atomic-walker", action="store_true", help="Also test translated AMO/LR/SC and PTE A/D updates through the uncacheable data path")
    args = parser.parse_args()
    if "WALLY" not in os.environ:
        parser.error("Source ./setup.sh first")
    root = Path(os.environ["WALLY"])
    work = args.work_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    manifest_path = work / "results.json"
    manifest_path.unlink(missing_ok=True)  # Never retain a previous PASS after a failed rerun.
    reference = subprocess.check_output(["git", "rev-parse", "--verify", f"{args.upstream_ref}^{{commit}}"], cwd=root, text=True).strip()
    sources = []
    for name in ("clint", "plic"):
        content = subprocess.check_output(["git", "show", f"{reference}:src/uncore/{name}_apb.sv"], cwd=root, text=True)
        content = content.replace(f"module {name}_apb ", f"module {name}_upstream_apb ", 1)
        target = work / f"{name}_upstream_apb.sv"
        target.write_text(content)
        sources.append(target)
    sources += [root / f"src/uncore/{name}{suffix}_apb.sv" for name in ("clint", "plic") for suffix in ("", "_multicore")]
    sources += [root / "tests/multicore/singlecore_peripherals_tb.sv", root / "src/generic/flop/flopr.sv"]
    results = []
    for config in ("rv32gc", "rv64gc"):
        for nsrc in (14, 63):
            name = f"{config}-{nsrc}"
            build = work / name
            command = ["verilator", "--binary", "--timing", "--assert", "-j", "2", "--top-module", "singlecore_peripherals_tb",
                       f"-GNSOURCES={nsrc}", "--Mdir", str(build), f"-I{root}/config/shared", f"-I{root}/config/{config}",
                       str(root / "src/cvw.sv"), *map(str, sources)]
            (work / f"{name}-command.json").write_text(json.dumps(command, indent=2) + "\n")
            with (work / f"{name}-build.log").open("w") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            result = subprocess.run([str(build / "Vsinglecore_peripherals_tb")], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            (work / f"{name}-run.log").write_text(result.stdout)
            if result.returncode or "PASS:" not in result.stdout:
                raise SystemExit(f"FAIL {name}: see {work / f'{name}-run.log'}")
            print(result.stdout.splitlines()[0], flush=True)
            results.append({"config": config, "sources": nsrc, "verdict": "PASS"})
    results.extend(check_clocks(root, work))
    if args.atomic_walker:
        results.append(check_atomic_walker(root, work))
    evidence_sources = set(sources) | set((root / "src").rglob("*.sv")) | set((root / "config/shared").glob("*.vh"))
    evidence_sources.update(root / "config" / cfg / "config.vh" for cfg in ("rv32i", "rv32gc", "rv64gc"))
    evidence_sources.update((root / "testbench/common").glob("*.sv"))
    evidence_sources.update([root / "testbench/testbench.sv", root / "sim/verilator/wrapper.c",
                             root / "tests/coverage/WALLY-init-lib.h", root / "tests/coverage/WALLY-selfcheck.h",
                             root / "examples/link/link.ld", Path(__file__).resolve(), root / "tests/multicore/soc_clock_tb.sv",
                             root / "tests/multicore/atomic_walker_monitor.svh", root / "tests/coverage/amoADUpdate.S"])
    manifest = {"source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
                "upstream_commit": reference,
                "verilator": subprocess.check_output(["verilator", "--version"], text=True).strip(),
                "sources": {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(evidence_sources)}, "results": results}
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
