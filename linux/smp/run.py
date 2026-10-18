# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Run the generated SMP boot test on the Wally RTL or QEMU reference machine."""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT / "linux/smp"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=Path.home() / "wally-smp-work")
    parser.add_argument("--sim", choices=["verilator", "qemu"], default="verilator")
    parser.add_argument("--cycles", type=int, default=1000000000)
    parser.add_argument("--timeout", type=int, default=300, help="QEMU wall time in seconds")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--reuse", action="store_true", help="Reuse an already compiled RTL model")
    args = parser.parse_args()
    work = args.work.resolve()
    manifest = json.loads((work / "manifest.json").read_text())
    cores = manifest["cores"]
    if args.sim == "qemu":
        command = [
            "qemu-system-riscv64",
            "-M",
            "virt",
            "-m",
            "128M",
            "-smp",
            str(cores),
            "-bios",
            str(work / "opensbi/platform/generic/firmware/fw_jump.bin"),
            "-kernel",
            str(work / "kernel/arch/riscv/boot/Image"),
            "-dtb",
            str(work / "wally-smp.dtb"),
            "-nographic",
            "-no-reboot",
        ]
        print(" ".join(command), flush=True)
        log = work / "qemu.log"
        with log.open("w") as stream:
            proc = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT)
            import time

            try:
                start = time.monotonic()
                while proc.poll() is None and time.monotonic() - start < args.timeout:
                    output = log.read_text(errors="replace")
                    if "WALLY_SMP_PASS" in output or "WALLY_SMP_FAIL" in output:
                        break
                    time.sleep(0.2)
            finally:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
        output = log.read_text(errors="replace")
        print(output)
        return 0 if "WALLY_SMP_PASS" in output and "WALLY_SMP_FAIL" not in output else 1
    if "WALLY" not in os.environ:
        parser.error("Source ./setup.sh first")
    build = work / f"rtl-{cores}"
    exe = build / "Vlinux_tb"
    if not args.reuse:
        subprocess.run(["perl", str(ROOT / "bin/derivgen.pl")], check=True)
        sources = sorted(p for p in (ROOT / "src").rglob("*.sv") if p.name != "cvw.sv")
        command = [
            "verilator",
            "--cc",
            "--exe",
            "--build",
            "--assert",
            "-CFLAGS",
            "-O3",
            "-j",
            str(args.jobs),
            "--top-module",
            "linux_tb",
            f"-GNCORES={cores}",
            "--Mdir",
            str(build),
            f"-I{ROOT / 'config/shared'}",
            f"-I{ROOT / 'config/deriv/multicore_linux'}",
            str(ROOT / "src/cvw.sv"),
            str(HERE / "linux_tb.sv"),
            *map(str, sources),
            str(HERE / "sim_main.cpp"),
            str(ROOT / "tests/multicore/dpi.cpp"),
        ]
        with (work / "rtl-build.log").open("w") as log:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    with (work / "rtl.log").open("w") as log:
        return subprocess.run([str(exe), f"+ram={work / 'ram.memfile'}", f"+rom={work / 'boot.memfile'}", f"+cycles={args.cycles}"], stdout=log, stderr=subprocess.STDOUT).returncode


if __name__ == "__main__":
    sys.exit(main())
