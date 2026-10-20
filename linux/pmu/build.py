#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Build isolated single-core Linux/OpenSBI/perf images without modifying installed tools."""

import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT / "linux/pmu"


def run(command, **kwargs):
    print(" ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True, **kwargs)


def hexfile(binary, output, offset=0):
    data = binary.read_bytes()
    data += bytes((-len(data)) % 8)
    with output.open("a") as stream:
        stream.write(f"@{offset // 8:x}\n")
        stream.writelines(f"{int.from_bytes(data[i:i+8], 'little'):016x}\n" for i in range(0, len(data), 8))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel-source", type=Path, required=True)
    parser.add_argument("--opensbi-source", type=Path, required=True)
    parser.add_argument("--cross-prefix", required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    cross = args.cross_prefix
    kernel = args.kernel_source.resolve()
    env = {k: v for k, v in os.environ.items() if k not in ("LD_LIBRARY_PATH", "DEBUG")}
    for program in ["init", "workload"]:
        run([cross + "gcc", "-O2", "-static", "-march=rv64imafdc_zicsr_zifencei", "-mabi=lp64d", HERE / (program + ".c"), "-o", work / program], env=env)
    perf = work / "perf-build"
    perf.mkdir(exist_ok=True)
    options = ["NO_LIBELF=1", "NO_LIBTRACEEVENT=1", "NO_LIBBPF=1", "NO_LIBNUMA=1", "NO_LIBPYTHON=1", "NO_SLANG=1", "NO_LIBAUDIT=1", "NO_LIBCRYPTO=1", "NO_LIBDW_DWARF_UNWIND=1", "NO_LIBUNWIND=1", "NO_ZSTD=1", "NO_LIBCAP=1", "NO_SDT=1", "NO_JVMTI=1", "NO_LIBBFD=1", "NO_LIBPFM4=1", "NO_LLVM=1", "NO_DEMANGLE=1", "WERROR=0", "LDFLAGS=-static", "PKG_CONFIG=/bin/false"]
    run(["make", "-C", kernel / "tools/perf", f"O={perf}/", "ARCH=riscv", f"CROSS_COMPILE={cross}", *options, f"-j{args.jobs}"], env=env)
    cpio = work / "initramfs.list"
    cpio.write_text("dir /dev 0755 0 0\ndir /proc 0755 0 0\ndir /sys 0755 0 0\nnod /dev/console 0600 0 0 c 5 1\n" + "".join(f"file /{n} {p} 0755 0 0\n" for n, p in [("init", work / "init"), ("workload", work / "workload"), ("perf", perf / "perf")]))
    kout = work / "kernel"
    kout.mkdir(exist_ok=True)
    (kout / ".config").write_text((HERE / "kernel.config").read_text() + f'\nCONFIG_INITRAMFS_SOURCE="{cpio}"\n')
    base = ["make", "-C", kernel, f"O={kout}", "ARCH=riscv", f"CROSS_COMPILE={cross}"]
    run([*base, "olddefconfig"], env=env)
    for symbol in ["PERF_EVENTS", "RISCV_PMU", "RISCV_PMU_SBI"]:
        if f"CONFIG_{symbol}=y" not in (kout / ".config").read_text():
            raise SystemExit(f"Kernel did not enable {symbol}")
    run([*base, f"-j{args.jobs}", "Image"], env=env)
    sbi = work / "opensbi"
    run(["make", "-C", args.opensbi_source.resolve(), f"O={sbi}", "PLATFORM=generic", "DEBUG=", "OPENSBI_VERSION_GIT=", f"CROSS_COMPILE={cross}", "PLATFORM_RISCV_ISA=rv64imafdc_zicsr_zifencei", "FW_JUMP_ADDR=0x80200000", "FW_JUMP_FDT_ADDR=0x87000000", f"-j{args.jobs}"], env=env)
    dts = (ROOT / "linux/devicetree/wally-virt.dts").read_text()
    dts = re.sub(r'    linux,initrd-(?:end|start) = .*;\n', '', dts)
    dts = dts.replace('bootargs = "root=/dev/vda ro";', 'bootargs = "earlycon=uart8250,mmio,0x10000000 console=ttyS0,115200 loglevel=6 rdinit=/init";')
    dts = dts.replace('0x00 0x10000000>;', '0x00 0x08000000>;')
    (work / "wally-pmu.dts").write_text(dts)
    run(["dtc", "-i", ROOT / "linux/devicetree", "-I", "dts", "-O", "dtb", "-o", work / "wally-pmu.dtb", work / "wally-pmu.dts"])
    run([cross + "gcc", "-nostdlib", "-nostartfiles", "-march=rv64i_zicsr", "-mabi=lp64", "-Wl,-Ttext=0x1000", "-Wl,--build-id=none", "-Wl,--no-relax", HERE / "boot.S", "-o", work / "boot.elf"], env=env)
    run([cross + "objcopy", "-O", "binary", work / "boot.elf", work / "boot.bin"], env=env)
    ram = work / "ram.memfile"
    rom = work / "boot.memfile"
    ram.write_text(""); rom.write_text("")
    hexfile(work / "boot.bin", rom)
    hexfile(sbi / "platform/generic/firmware/fw_jump.bin", ram)
    hexfile(kout / "arch/riscv/boot/Image", ram, 0x200000)
    hexfile(work / "wally-pmu.dtb", ram, 0x7000000)
    files = [ram, rom, work / "wally-pmu.dtb", kout / "arch/riscv/boot/Image", sbi / "platform/generic/firmware/fw_jump.bin", kout / ".config", work / "init", work / "workload", perf / "perf"]
    manifest = {"kind": "wally-native-single-core-pmu", "config": "pmu_linux", "counters": 32, "sampling": False, "sha256": {str(p.relative_to(work)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}, "kernel_release": subprocess.check_output([*map(str, base), "-s", "kernelrelease"], env=env, text=True).strip()}
    (work / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
