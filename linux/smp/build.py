# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Build isolated OpenSBI/Linux SMP test artifacts using an existing Buildroot toolchain."""

import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT / "linux/smp"


def run(command, **kwargs):
    print(" ".join(str(x) for x in command), flush=True)
    subprocess.run([str(x) for x in command], check=True, **kwargs)


def hexfile(binary, output, offset=0):
    data = binary.read_bytes()
    data += bytes((-len(data)) % 8)
    with output.open("a") as f:
        f.write(f"@{offset // 8:x}\n")
        f.writelines(f"{int.from_bytes(data[i : i + 8], 'little'):016x}\n" for i in range(0, len(data), 8))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--buildroot", type=Path, required=True)
    parser.add_argument("--work", type=Path, default=Path.home() / "wally-smp-work")
    parser.add_argument("--cores", type=int, default=2)
    parser.add_argument("--cache-mode", choices=["shared", "msi"], default="shared")
    parser.add_argument("--private-icache", action="store_true")
    parser.add_argument("--icache-words", type=int, default=256)
    parser.add_argument("--local-dcache-writes", action="store_true")
    parser.add_argument("--local-dcache-reads", action="store_true")
    parser.add_argument("--cache-words", type=int, default=256)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if not 1 <= args.cores <= 8:
        parser.error("Expected 1..8 cores")
    if (args.private_icache or args.local_dcache_reads or args.local_dcache_writes) and args.cache_mode != "msi":
        parser.error("Private cache local paths require MSI mode")
    if args.icache_words < 2 or args.icache_words & (args.icache_words - 1):
        parser.error("--icache-words must be a power of two >= 2")
    if args.cache_words < 2 or args.cache_words & (args.cache_words - 1):
        parser.error("--cache-words must be a power of two >= 2")
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    br = args.buildroot.resolve()
    cross = str(br / "output/host/bin/riscv64-buildroot-linux-gnu-")
    sources = work / "sources"
    sources.mkdir(exist_ok=True)
    kernel = sources / "linux-6.19.14"
    if not (kernel / ".wally-extracted").exists():
        archive = br / "dl/linux/linux-6.19.14.tar.xz"
        # Kernel symlinks include parent components: use tar's standard Linux
        # archive semantics on this archive already verified by Buildroot.
        run(["tar", "-xJf", archive, "-C", sources])
        (kernel / ".wally-extracted").touch()
    sbi = br / "output/build/opensbi-1.7"
    env = os.environ.copy()
    env.pop("LD_LIBRARY_PATH", None)
    env.pop("DEBUG", None)  # A nonempty value (even "release") selects OpenSBI -O0.
    run([cross + "gcc", "-O2", "-static", "-march=rv64imafdc_zicsr_zifencei", "-mabi=lp64d", f"-DEXPECTED_CPUS={args.cores}", HERE / "init.c", "-o", work / "init"], env=env)
    cpio = work / "initramfs.list"
    cpio.write_text(f"dir /dev 0755 0 0\ndir /proc 0755 0 0\ndir /sys 0755 0 0\nnod /dev/console 0600 0 0 c 5 1\nfile /init {work / 'init'} 0755 0 0\n")
    kout = work / "kernel"
    kout.mkdir(exist_ok=True)
    config = (HERE / "kernel.config").read_text() + f'\nCONFIG_INITRAMFS_SOURCE="{cpio}"\n'
    (kout / ".config").write_text(config)
    base = ["make", "-C", kernel, f"O={kout}", "ARCH=riscv", f"CROSS_COMPILE={cross}"]
    run([*base, "olddefconfig"], env=env)
    run([*base, f"-j{args.jobs}", "Image"], env=env)
    sout = work / "opensbi"
    sbi_command = ["make", "-C", sbi, f"O={sout}", "PLATFORM=generic", "DEBUG=", "OPENSBI_VERSION_GIT=", f"CROSS_COMPILE={cross}", "PLATFORM_RISCV_ISA=rv64imafdc_zicsr_zifencei", "FW_JUMP_ADDR=0x80200000", "FW_JUMP_FDT_ADDR=0x87000000"]
    recipe = json.dumps([str(x) for x in sbi_command]) + "\n"
    marker = sout / ".wally-options.json"
    # OpenSBI make does not track command-line flag changes in object files.
    if sout.exists() and (not marker.exists() or marker.read_text() != recipe):
        run([*sbi_command, "clean"], env=env)
    run([*sbi_command, f"-j{args.jobs}"], env=env)
    marker.write_text(recipe)
    run(["python3", HERE / "devicetree.py", "--cores", args.cores, "--cache-mode", args.cache_mode,
         "--cache-words", args.cache_words, "--icache-words", args.icache_words,
         *(["--private-icache"] if args.private_icache else []),
         *(["--local-dcache-reads"] if args.local_dcache_reads else []),
         *(["--local-dcache-writes"] if args.local_dcache_writes else []), "--output", work / "wally-smp.dts"])
    run(["dtc", "-I", "dts", "-O", "dtb", "-o", work / "wally-smp.dtb", work / "wally-smp.dts"])
    run([cross + "gcc", "-nostdlib", "-nostartfiles", "-march=rv64i_zicsr", "-mabi=lp64", "-Wl,-Ttext=0x1000", "-Wl,--build-id=none", "-Wl,--no-relax", HERE / "boot.S", "-o", work / "boot.elf"])
    run([cross + "objcopy", "-O", "binary", work / "boot.elf", work / "boot.bin"])
    if (sout / "platform/generic/firmware/fw_jump.bin").stat().st_size > 0x200000:
        raise SystemExit("OpenSBI overlaps the Linux load address")
    if (kout / "arch/riscv/boot/Image").stat().st_size > 0x6E00000:
        raise SystemExit("Linux overlaps the DTB load address")
    if (work / "boot.bin").stat().st_size > 0x1000:
        raise SystemExit("Boot shim exceeds ROM size")
    rom = work / "boot.memfile"
    ram = work / "ram.memfile"
    rom.write_text("")
    ram.write_text("")
    hexfile(work / "boot.bin", rom)
    hexfile(sout / "platform/generic/firmware/fw_jump.bin", ram)
    hexfile(kout / "arch/riscv/boot/Image", ram, 0x200000)
    hexfile(work / "wally-smp.dtb", ram, 0x7000000)
    artifacts = [rom, ram, work / "wally-smp.dtb", kout / "arch/riscv/boot/Image", sout / "platform/generic/firmware/fw_jump.bin", kout / ".config", work / "init"]
    manifest = {
        "cores": args.cores,
        "cache_mode": args.cache_mode,
        "cache_words": args.cache_words,
        "private_icache": args.private_icache,
        "icache_words": args.icache_words,
        "local_dcache_reads": args.local_dcache_reads,
        "local_dcache_writes": args.local_dcache_writes,
        "linux": "6.19.14",
        "opensbi": "1.7",
        "ram_mb": 128,
        "compiler": subprocess.check_output([cross + "gcc", "--version"], text=True, env=env).splitlines()[0],
        "sha256": {str(p.relative_to(work)): hashlib.sha256(p.read_bytes()).hexdigest() for p in artifacts},
    }
    (work / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
