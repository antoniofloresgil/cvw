#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Run multicore tests after sourcing setup.sh; no commercial simulator."""

import argparse
import os
import subprocess
from pathlib import Path


def run(command, log=None):
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
    parser.add_argument("--cores", type=int, nargs="+", default=[1, 2, 3])
    parser.add_argument("--latency", type=int, nargs="+", default=[0, 3])
    parser.add_argument("--suite", choices=["smoke", "atomic", "uart"], default="smoke")
    caches = parser.add_mutually_exclusive_group()
    caches.add_argument("--shared-cache", action="store_true", help="Use the shared coherent physical cache")
    caches.add_argument("--private-dcache", action="store_true", help="Use private MSI data caches (automatically bypassed with one hart)")
    parser.add_argument("--cache-words", type=int, default=256, help="AHB words per private data cache; power of two >= 2")
    parser.add_argument("--work-dir", type=Path, help="Build/log directory; use native Linux storage on case-insensitive hosts")
    parser.add_argument("--unit-only", action="store_true", help="Run bus/cache/peripheral tests without full-core models")
    args = parser.parse_args()
    if any(not 1 <= n <= 4 for n in args.cores):
        parser.error("The smoke program reserves stacks for 1..4 harts")
    if any(not 0 <= latency <= 255 for latency in args.latency):
        parser.error("RAM latency must be in the range 0..255")
    if args.cache_words < 2 or args.cache_words & (args.cache_words - 1):
        parser.error("--cache-words must be a power of two >= 2")
    if "WALLY" not in os.environ:
        parser.error("Source ./setup.sh from the repository root first")
    root = Path(os.environ["WALLY"])
    tests = root / "tests/multicore"
    work = args.work_dir.resolve() if args.work_dir else root / "sim/verilator/wkdir/multicore"
    work.mkdir(parents=True, exist_ok=True)
    run(["perl", root / "bin/derivgen.pl"], work / "deriv.log")

    def build_test(top, config, sources, name, parameters=()):
        build = work / name
        print(f"Building {name}", flush=True)
        run(["verilator", "--binary", "--timing", "--assert", "-j", "2", "--top-module", top, *parameters, "--Mdir", build, f"-I{root / 'config/shared'}", f"-I{root / 'config' / config}", root / "src/cvw.sv", *sources], work / f"{name}.log")
        return build / f"V{top}"

    for config in ("rv64gc", "rv32gc"):
        executable = build_test("peripherals_tb", config, [tests / "peripherals_tb.sv", root / "src/uncore/clint_apb.sv", root / "src/uncore/plic_apb.sv", root / "src/generic/flop/flopr.sv"], f"peripherals-{config}")
        run([executable])
    executable = build_test("bus_tb", "rv64gc", [tests / "bus_tb.sv", root / "src/ebu/ahbmulticore.sv"], "bus")
    run([executable])
    executable = build_test("atomic_bus_tb", "rv64gc", [tests / "atomic_bus_tb.sv", root / "src/ebu/ahbmulticore.sv"], "atomic-bus")
    run([executable])
    if args.shared_cache:
        executable = build_test("cache_tb", "rv64gc", [tests / "cache_tb.sv", root / "src/ebu/ahbsharedcache.sv"], "cache")
        run([executable])
    if args.private_dcache:
        for config in ("rv64gc", "rv32gc"):
            for cores in (2, 3):
                for latency in args.latency:
                    name = f"msi-{config}-{cores}-{latency}"
                    executable = build_test("msi_tb", config,
                        [tests / "msi_tb.sv", root / "src/ebu/ahbmulticore.sv", root / "src/ebu/ahbmsicache.sv"],
                        name, [f"-GNCORES={cores}", f"-GLATENCY={latency}"])
                    run([executable], work / f"{name}-run.log")
    if args.unit_only:
        return
    config = "multicore_atomic" if args.suite == "atomic" else "multicore"
    if args.shared_cache:
        config = "multicore_coherent"
    if args.private_dcache:
        config = "multicore_msi"
    assembly = tests / ("atomics.S" if args.suite == "atomic" else "uart.S" if args.suite == "uart" else "smoke.S")
    march = "rv64ia_zicsr_zifencei" if args.suite == "atomic" else "rv64i_zicsr"
    for cores in args.cores:
        image = build_image(assembly, work / f"{args.suite}-{cores}.elf", march, cores, tests / "link.ld")
        smoke_image = build_image(tests / "smoke.S", work / f"smoke-{cores}.elf", "rv64i_zicsr", cores, tests / "link.ld") if args.suite == "atomic" else None
        for latency in args.latency:
            executable = build_test(
                "soc_tb",
                f"deriv/{config}",
                [tests / "soc_tb.sv", tests / "dpi.cpp", *sorted(p for p in (root / "src").rglob("*.sv") if p.name != "cvw.sv")],
                f"{args.suite}-soc-{cores}-{latency}" + ("-shared" if args.shared_cache else "-msi" if args.private_dcache else ""),
                [f"-GNCORES={cores}", f"-GLATENCY={latency}", "-GSHARED_CACHE=1'b1" if args.shared_cache else "-GSHARED_CACHE=1'b0",
                 "-GPRIVATE_DCACHE=1'b1" if args.private_dcache else "-GPRIVATE_DCACHE=1'b0",
                 f"-GPRIVATE_DCACHE_WORDS={args.cache_words}"],
            )
            run([executable, f"+image={image}", f"+suite={args.suite}"])
            if smoke_image is not None:
                run([executable, f"+image={smoke_image}", "+suite=smoke-on-atomic-config"])


if __name__ == "__main__":
    main()
