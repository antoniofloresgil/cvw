#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Run multicore tests after sourcing setup.sh; no commercial simulator."""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'config/multicore'))
import profiles


def run(command, log=None):
    if log is not None:
        log.with_suffix(".command.json").write_text(json.dumps(list(map(str, command)), indent=2) + "\n")
    try:
        if log is None:
            subprocess.run([str(x) for x in command], check=True)
        else:
            with log.open("w") as stream:
                subprocess.run([str(x) for x in command], stdout=stream, stderr=subprocess.STDOUT, check=True)
    except subprocess.CalledProcessError as error:
        detail = f"See {log}" if log else f"Executable: {command[0]}"
        raise SystemExit(f"Test command failed with exit code {error.returncode}. {detail}") from error


def build_image(source, elf, march, cores, linker):
    """Build a little-endian RV64 image for the shared RAM testbench."""
    run(["riscv64-unknown-elf-gcc", f"-march={march}", "-mabi=lp64", "-nostdlib", "-nostartfiles", "-Wl,--no-relax", f"-DNCORES={cores}", f"-T{linker}", source, "-o", elf])
    binary = elf.with_suffix(".bin")
    image = elf.with_suffix(".memfile")
    run(["riscv64-unknown-elf-objcopy", "-O", "binary", elf, binary])
    data = binary.read_bytes()
    data += bytes((-len(data)) % 8)
    image.write_text("".join(f"{int.from_bytes(data[i : i + 8], 'little'):016x}\n" for i in range(0, len(data), 8)))
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    profiles.add_arguments(parser, multiple_cores=True)
    parser.add_argument("--latency", type=int, nargs="+", default=[0, 3])
    parser.add_argument("--suite", choices=["smoke", "atomic", "uart", "exclusive"], default="smoke")
    parser.add_argument("--work-dir", type=Path, help="Build/log directory; use native Linux storage on case-insensitive hosts")
    parser.add_argument("--skip-deriv", action="store_true", help="Use already generated configurations; for an enclosing regression that builds them once")
    parser.add_argument("--unit-only", action="store_true", help="Run bus/cache/peripheral tests without full-core models")
    args = parser.parse_args()
    args.cores = args.cores or [1, 2, 3]
    if any(not 1 <= n <= 4 for n in args.cores):
        parser.error("The smoke program reserves stacks for 1..4 harts")
    if any(not 0 <= latency <= 255 for latency in args.latency):
        parser.error("RAM latency must be in the range 0..255")
    try:
        topology = profiles.from_args(args, cores=max(args.cores))
        for cores in args.cores:
            profiles.require_capabilities({**topology, 'NCORES': cores}, args.require_capability)
    except ValueError as error:
        parser.error(str(error))
    for key, value in topology.items():
        alias = next((a for a, k in profiles.ALIASES.items() if k == key), key.lower())
        if key != 'NCORES':
            setattr(args, alias, value)
    if "WALLY" not in os.environ:
        parser.error("Source ./setup.sh from the repository root first")
    root = Path(os.environ["WALLY"])
    tests = root / "tests/multicore"
    work = args.work_dir.resolve() if args.work_dir else root / "sim/verilator/wkdir/multicore"
    work.mkdir(parents=True, exist_ok=True)
    profiles.check_generated()
    if not args.skip_deriv:
        run(["perl", root / "bin/derivgen.pl"], work / "deriv.log")

    def build_test(top, config, sources, name, parameters=()):
        sources = list(sources)
        for parent, dependencies in {
            'ahbmulticore.sv': ('corebus_contract.sv', 'multicore_reservations.sv', 'multicore_icache_bank.sv'),
            'ahbmsicache.sv': ('multicore_dcache_data.sv',),
        }.items():
            if root / 'src/ebu' / parent in sources:
                for dependency in dependencies:
                    path = root / 'src/ebu' / dependency
                    if path not in sources:
                        sources.append(path)
        build = work / name
        print(f"Building {name}", flush=True)
        # Verilator 5.036 can emit an undeclared fork sync in split coroutine
        # code for these benches. Keep their generated C++ together; all
        # concurrent stimuli and assertions remain enabled.
        run(["verilator", "--binary", "--timing", "--assert", "-j", "2", "--top-module", top, *(["--output-split", "0"] if top in ("msi_tb", "msifabric_tb") else []), *parameters, "--Mdir", build, f"-I{root / 'config/shared'}", f"-I{tests}", f"-I{root / 'config' / config}", root / "src/cvw.sv", *sources], work / f"{name}.log")
        return build / f"V{top}"

    for config in ("rv64gc", "rv32gc"):
        executable = build_test("peripherals_tb", config, [tests / "peripherals_tb.sv", root / "src/uncore/clint_multicore_apb.sv", root / "src/uncore/plic_multicore_apb.sv", root / "src/generic/flop/flopr.sv"], f"peripherals-{config}")
        run([executable])
    executable = build_test("bus_tb", "rv64gc", [tests / "bus_tb.sv", root / "src/ebu/ahbmulticore.sv"], "bus")
    run([executable])
    executable = build_test("atomic_bus_tb", "rv64gc", [tests / "atomic_bus_tb.sv", root / "src/ebu/ahbmulticore.sv"], "atomic-bus")
    run([executable])
    if args.shared_cache:
        executable = build_test("cache_tb", "rv64gc", [tests / "cache_tb.sv", root / "src/ebu/ahbsharedcache.sv"], "cache")
        run([executable])
    if args.cache_bursts:
        for config in ("rv64gc", "rv32gc"):
            for latency in args.latency:
                name = f"lineburst-{config}-{latency}"
                executable = build_test("lineburst_tb", config,
                    [tests / "lineburst_tb.sv", root / "src/ebu/ahblineburst.sv"], name,
                    [f"-GLATENCY={latency}"])
                run([executable], work / f"{name}-run.log")
    if args.private_dcache:
        for config in ("rv64gc", "rv32gc"):
            for cores in (2, 3):
                for latency in args.latency:
                    name = f"mesi{int(args.mesi)}-burst{int(args.cache_bursts)}-b{args.coherence_banks}-c2c{int(args.cache_to_cache)}-msi-{config}-{cores}-{latency}-d{args.cache_words}x{args.cache_line_words}-i{args.icache_words}x{args.icache_line_words}"
                    top = "msifabric_tb" if args.coherence_banks > 1 else "msi_tb"
                    executable = build_test(top, config,
                        [tests / f"{top}.sv", root / "src/ebu/ahbmulticore.sv", root / "src/ebu/ahbmsicache.sv", root / "src/ebu/ahbmsifabric.sv", root / "src/ebu/ahblineburst.sv", root / "src/ebu/ahbburstmux.sv"],
                        name, [*([f"-GBANKS={args.coherence_banks}"] if args.coherence_banks > 1 else []), f"-GNCORES={cores}", f"-GLATENCY={latency}",
                               f"-GWORDS={args.cache_words}", f"-GICACHE_WORDS={args.icache_words}",
                               f"-GMESI=1'b{int(args.mesi)}", f"-GCACHE_BURSTS=1'b{int(args.cache_bursts)}", f"-GCACHE_TO_CACHE=1'b{int(args.cache_to_cache)}", f"-GLINE_WORDS={args.cache_line_words}", f"-GICACHE_LINE_WORDS={args.icache_line_words}", f"-GPRIVATE_ICACHE=1'b{int(args.private_icache)}",
                               f"-GLOCAL_DCACHE_READS=1'b{int(args.local_dcache_reads)}",
                               f"-GLOCAL_DCACHE_WRITES=1'b{int(args.local_dcache_writes)}"])
                    run([executable], work / f"{name}-run.log")
    if args.unit_only:
        return
    config = "multicore_atomic" if args.suite == "atomic" else "multicore"
    if args.shared_cache:
        config = "multicore_coherent"
    if args.private_dcache:
        config = "multicore_msi"
    assembly = tests / ("atomics.S" if args.suite == "atomic" else "uart.S" if args.suite == "uart" else "exclusive.S" if args.suite == "exclusive" else "smoke.S")
    march = "rv64ia_zicsr_zifencei" if args.suite == "atomic" else "rv64i_zicsr"
    for cores in args.cores:
        image = build_image(assembly, work / f"{args.suite}-{cores}.elf", march, cores, tests / "link.ld")
        smoke_image = build_image(tests / "smoke.S", work / f"smoke-{cores}.elf", "rv64i_zicsr", cores, tests / "link.ld") if args.suite == "atomic" else None
        for latency in args.latency:
            executable = build_test(
                "soc_tb",
                f"deriv/{config}",
                [tests / "soc_tb.sv", tests / "dpi.cpp", root / "testbench/common/bus_fault_guard.sv", *sorted(p for p in (root / "src").rglob("*.sv") if p.name != "cvw.sv")],
                f"mesi{int(args.mesi)}-burst{int(args.cache_bursts)}-b{args.coherence_banks}-c2c{int(args.cache_to_cache)}-{args.suite}-soc-{cores}-{latency}-d{args.cache_words}x{args.cache_line_words}-i{args.icache_words}x{args.icache_line_words}" + ("-shared" if args.shared_cache else "-msi" if args.private_dcache else "") + ("-icache" if args.private_icache else "") + ("-localreads" if args.local_dcache_reads else "") + ("-localwrites" if args.local_dcache_writes else ""),
                [f"-GLATENCY={latency}", *profiles.verilator_args({**topology, 'NCORES': cores})],
            )
            run([executable, f"+image={image}", f"+suite={args.suite}"])
            if smoke_image is not None:
                run([executable, f"+image={smoke_image}", "+suite=smoke-on-atomic-config"])


if __name__ == "__main__":
    main()
