#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""SD card image that starts the FPGA board from a checkpoint.

    sdimage.py <checkpoint dir>/<k> <image> [--sysclock 20000000] [--ext-mem-range 0x1FFFFFFF]

The board's ZSBL (fpga/zsbl, unchanged) loads the first three GPT partitions of the card: the first at the top of the
DDR3 less 16 MiB (meant for the device tree), the second at 0x80000000 (OpenSBI), the third at 0x80200000 (Linux), then
jumps to 0x80000000 in M-mode.  Here the first is the restore program (mkrestore.py --fpga, run by this script), the
second the checkpoint's whole RAM (ram.bin in plain byte order) with its first doubleword replaced by a jump to the
restore program, which puts it back, and the third one block of the same RAM (the ZSBL loads it over the same bytes).
The image is about 257 MiB; write it with
    sudo dd if=<image> of=/dev/sdX bs=4M conv=fsync status=progress
which replaces everything on the card.  The ZSBL then reads the RAM through SPI at 10 MHz (about 7.5 minutes) and the
restore program returns to the checkpoint's instruction; the console is the board's UART at 115200 baud.
The RAM holds SPEC CPU 2026 content: the image is for the licensee's own cards, never for git or publication.
"""
import argparse
import array
import pathlib
import subprocess
import sys

import mkrestore

SECTOR = 512
RAM_SIZE = 256 << 20
FIRST = 34                       # the first usable sector after the protective MBR and the primary GPT


def jump(offset):
    """auipc t0, offset; jr t0 (offset a multiple of 4 KiB below 2 GiB)."""
    assert offset % 4096 == 0 and 0 <= offset < 1 << 31
    return (0x297 | offset).to_bytes(4, "little") + (0x00028067).to_bytes(4, "little")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir", type=pathlib.Path, help="one checkpoint (with ram.bin and state.txt)")
    ap.add_argument("image", type=pathlib.Path)
    ap.add_argument("--sysclock", type=int, default=20000000, help="the board's clock in Hz (20000000: Vivado)")
    ap.add_argument("--ext-mem-range", default="0x1FFFFFFF",
                    help="EXT_MEM_RANGE of the board's configuration (0x1FFFFFFF: fpganexysvideo)")
    args = ap.parse_args()
    here = pathlib.Path(__file__).resolve().parent
    subprocess.run([sys.executable, here / "mkrestore.py", args.dir, "--fpga", "--sysclock", str(args.sysclock),
                    "--ext-mem-range", args.ext_mem_range], check=True)
    restore = (args.dir / "restore-fpga.bin").read_bytes()
    base = mkrestore.fpga_base(int(args.ext_mem_range, 0))

    ram = array.array("Q")
    with open(args.dir / "ram.bin", "rb") as f:
        ram.fromfile(f, RAM_SIZE // 8)
    if sys.byteorder == "little":
        ram.byteswap()           # the testbench's order (most significant byte of each doubleword first) to memory order
    ram = ram.tobytes()
    kernel_off = 0x200000        # the ZSBL's KERNEL_ADDRESS less 0x80000000

    parts = [("restore", restore), ("ram", jump(base - mkrestore.RAM_BASE) + ram[8:]),
             ("ram-copy", ram[kernel_off:kernel_off + SECTOR])]
    starts, lba = [], FIRST
    for _, data in parts:
        starts.append(lba)
        lba += (len(data) + SECTOR - 1) // SECTOR
    total = lba + 33                                   # the backup GPT
    args.image.unlink(missing_ok=True)
    with open(args.image, "wb") as f:
        f.truncate(total * SECTOR)
    cmd = ["sgdisk", "-g", "--clear", "--set-alignment=1"]
    for i, ((name, data), start) in enumerate(zip(parts, starts), 1):
        cmd += [f"--new={i}:{start}:+{(len(data) + SECTOR - 1) // SECTOR}", f"--change-name={i}:{name}"]
    subprocess.run([*cmd, args.image], check=True, stdout=subprocess.DEVNULL)
    with open(args.image, "r+b") as f:
        for (_, data), start in zip(parts, starts):
            f.seek(start * SECTOR)
            f.write(data)
    # the ZSBL reads the partitions from the first three entries of the GPT: check them
    with open(args.image, "rb") as f:
        f.seek(SECTOR)
        hdr = f.read(SECTOR)
        f.seek(int.from_bytes(hdr[72:80], "little") * SECTOR)
        ents = f.read(3 * 128)
    for i, ((name, data), start) in enumerate(zip(parts, starts)):
        e = ents[128 * i:128 * (i + 1)]
        first, last = int.from_bytes(e[32:40], "little"), int.from_bytes(e[40:48], "little")
        if first != start or last - first + 1 != (len(data) + SECTOR - 1) // SECTOR:
            sys.exit(f"partition {i + 1} ({name}) is at {first}..{last}, not where it was written")
    print(f"{args.image}: {total * SECTOR >> 20} MiB; restore program at {base:#x}, RAM at {mkrestore.RAM_BASE:#x}")


if __name__ == "__main__":
    main()
