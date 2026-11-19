#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Restore program of a roickpt checkpoint for Wally's buildroot configuration.

  mkrestore.py <checkpoint dir> [--pmp-entries 16] [--plic-sources 53]

Reads <checkpoint dir>/state.txt (written by roickpt) and writes <checkpoint dir>/restore.S and bootmem.bin: the
BOOTROM image (0x1000, 4 KiB, in the testbench's byte order) that Wally runs from reset.  The program restores in
M-mode the CSRs, the floating-point registers, the CLINT, PLIC and UART registers, then the integer registers, and
returns with mret to the interrupted instruction in the mode QEMU was in.  The RAM is the checkpoint's ram.bin.

Not restored, on purpose: the counters (mcycle, minstret and mhpmcounter3-31 start at 0, mcountinhibit is 0 and
mhpmevent3-31 is 1, so every counter counts its event in every mode for the measurement), M-mode trap state that the
next trap overwrites (mepc, mcause, mtval), and stimecmp, which QEMU does not expose: it is set to the restored
mtime, so the kernel takes one early timer interrupt and programs the next one itself.
"""
import argparse
import pathlib
import subprocess
import sys
import tempfile

BOOTROM_BASE = 0x1000
BOOTROM_SIZE = 0x1000
CLINT, PLIC, UART = 0x02000000, 0x0C000000, 0x10000000

GPRS = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "fp", "s1", "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7",
        "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"]
FPRS = ["ft0", "ft1", "ft2", "ft3", "ft4", "ft5", "ft6", "ft7", "fs0", "fs1", "fa0", "fa1", "fa2", "fa3", "fa4", "fa5",
        "fa6", "fa7", "fs2", "fs3", "fs4", "fs5", "fs6", "fs7", "fs8", "fs9", "fs10", "fs11", "ft8", "ft9", "ft10", "ft11"]
# CSRs restored from QEMU's values, in this order (satp before the mode change, mstatus, mepc and mtvec at the end)
CSRS = ["medeleg", "mideleg", "mscratch", "menvcfg", "mcounteren", "senvcfg", "scounteren",
        "stvec", "sscratch", "sepc", "scause", "stval", "satp", "mie", "mip"]


def read_state(path):
    state = {}
    for line in path.read_text().splitlines():
        name, value = line.split()
        state[name] = int(value, 16)
    return state


def program(s, pmp_entries, plic_sources):
    data = []  # (label, value)

    def val(label, value):  # offset of a new data word from x31 (= data)
        data.append((label, value & (2**64 - 1)))
        return 8 * (len(data) - 1)

    a = []
    emit = a.append
    emit("    .section .text")
    emit("    .globl _start")
    emit("_start:")
    emit("    la      t0, fail")
    emit("    csrw    mtvec, t0")
    emit("    la      x31, data")
    emit("    li      t0, 0x6000")            # mstatus.FS on, for the floating-point registers
    emit("    csrs    mstatus, t0")
    for i, r in enumerate(FPRS):
        emit(f"    fld     f{i}, {val('f_' + r, s[r])}(x31)")
    emit(f"    ld      t0, {val('fcsr', s['fcsr'])}(x31)")
    emit("    csrw    fcsr, t0")
    for i in range(0, pmp_entries, 8):         # RV64: the even pmpcfg registers hold 8 entries each
        emit(f"    ld      t0, {val(f'pmpcfg{i // 4}', s[f'pmpcfg{i // 4}'])}(x31)")
        emit(f"    csrw    pmpcfg{i // 4}, t0")
    for i in range(pmp_entries):
        emit(f"    ld      t0, {val(f'pmpaddr{i}', s[f'pmpaddr{i}'])}(x31)")
        emit(f"    csrw    pmpaddr{i}, t0")
    for c in CSRS:
        emit(f"    ld      t0, {val(c, s[c])}(x31)")
        emit(f"    csrw    {c}, t0")
    emit("    sfence.vma")
    # counters for the measurement
    emit("    csrw    mcountinhibit, zero")
    emit("    li      t0, 1")
    for i in range(3, 32):
        emit(f"    csrw    mhpmevent{i}, t0")
    emit("    csrw    mcycle, zero")
    emit("    csrw    minstret, zero")
    for i in range(3, 32):
        emit(f"    csrw    mhpmcounter{i}, zero")
    # CLINT
    emit(f"    li      t1, {CLINT:#x}")
    emit(f"    ld      t0, {val('msip', s['clint.msip'])}(x31)")
    emit("    sw      t0, 0(t1)")
    emit(f"    li      t1, {CLINT + 0x4000:#x}")
    emit(f"    ld      t0, {val('mtimecmp', s['clint.mtimecmp'])}(x31)")
    emit("    sd      t0, 0(t1)")
    emit(f"    li      t1, {CLINT + 0xbff8:#x}")
    emit(f"    ld      t0, {val('mtime', s['clint.mtime'])}(x31)")
    emit("    sd      t0, 0(t1)")
    emit("    csrw    stimecmp, t0")              # QEMU does not expose stimecmp: one early timer interrupt
    # PLIC
    emit(f"    li      t1, {PLIC:#x}")
    for i in range(1, plic_sources + 1):
        emit(f"    li      t0, {s[f'plic.priority{i}']}")
        emit(f"    sw      t0, {4 * i}(t1)")
    for c in range(2):
        emit(f"    li      t1, {PLIC + 0x2000 + 0x80 * c:#x}")
        for w in range((plic_sources + 32) // 32):
            emit(f"    ld      t0, {val(f'plicen{c}_{w}', s[f'plic.enable{c}.{w}'])}(x31)")
            emit(f"    sw      t0, {4 * w}(t1)")
        emit(f"    li      t1, {PLIC + 0x200000 + 0x1000 * c:#x}")
        emit(f"    li      t0, {s[f'plic.threshold{c}']}")
        emit("    sw      t0, 0(t1)")
    # UART (16550): divisor through LCR.DLAB, then LCR, the FIFOs as Linux's 8250 driver sets them, IER, MCR, SCR
    emit(f"    li      t1, {UART:#x}")
    for off, value in [(3, s["uart.lcr"] | 0x80), (0, s["uart.dll"]), (1, s["uart.dlm"]), (3, s["uart.lcr"]),
                       (2, 0x81), (1, s["uart.ier"]), (4, s["uart.mcr"]), (7, s["uart.scr"])]:
        emit(f"    li      t0, {value}")
        emit(f"    sb      t0, {off}(t1)")
    # back to the interrupted code: mstatus with MPP = the mode, MPIE = its MIE; mtvec; mepc = pc
    priv = s["priv"]
    if priv == 3:
        sys.exit("the checkpoint is in M-mode: roickpt never takes one there")
    mstatus = s["mstatus"] & ~((3 << 11) | (1 << 7) | (1 << 3) | (1 << 17))  # MPP, MPIE, MIE, MPRV
    mstatus |= (priv << 11) | (((s["mstatus"] >> 3) & 1) << 7)
    emit(f"    ld      t0, {val('mstatus', mstatus)}(x31)")
    emit("    csrw    mstatus, t0")
    emit(f"    ld      t0, {val('mepc', s['pc'])}(x31)")
    emit("    csrw    mepc, t0")
    emit(f"    ld      t0, {val('mtvec', s['mtvec'])}(x31)")
    emit("    csrw    mtvec, t0")
    for i in range(1, 31):
        emit(f"    ld      x{i}, {val('x' + str(i), s[GPRS[i]])}(x31)")
    emit(f"    ld      x31, {val('x31', s[GPRS[31]])}(x31)")
    emit("    mret")
    emit("fail:")                                 # a trap while restoring: stop here (mcause, mepc tell why)
    emit("    j       fail")
    emit("    .balign 8")
    emit("data:")
    for label, value in data:
        emit(f"    .dword  {value:#x}  # {label}")
    return "\n".join(a) + "\n", len(data)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir", type=pathlib.Path)
    ap.add_argument("--pmp-entries", type=int, default=16)
    ap.add_argument("--plic-sources", type=int, default=53)
    args = ap.parse_args()
    state = read_state(args.dir / "state.txt")
    src, ndata = program(state, args.pmp_entries, args.plic_sources)
    if ndata * 8 > 2040:
        sys.exit("too much data: the offsets from data must stay within a 12-bit immediate")
    (args.dir / "restore.S").write_text(src)
    with tempfile.TemporaryDirectory() as tmp:
        elf, binary = pathlib.Path(tmp, "restore.elf"), pathlib.Path(tmp, "restore.bin")
        subprocess.run(["riscv64-unknown-elf-gcc", "-march=rv64gc_zicsr", "-mabi=lp64d", "-nostdlib", "-static",
                        f"-Wl,-Ttext={BOOTROM_BASE:#x}", "-Wl,--no-relax", "-o", elf, args.dir / "restore.S"], check=True)
        subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary", elf, binary], check=True)
        image = binary.read_bytes()
    if len(image) > BOOTROM_SIZE:
        sys.exit(f"restore program is {len(image)} bytes, the BOOTROM {BOOTROM_SIZE}")
    image = image.ljust(BOOTROM_SIZE, b"\0")
    # the testbench $freads 64-bit words, most significant byte first (linux/Makefile: objcopy --reverse-bytes=8)
    out = b"".join(image[i:i + 8][::-1] for i in range(0, BOOTROM_SIZE, 8))
    (args.dir / "bootmem.bin").write_bytes(out)
    print(f"{args.dir / 'bootmem.bin'}: {len(image.rstrip(bytes(1)))} bytes of program and data, "
          f"resumes at {state['pc']:#x} in {'USM'[state['priv']] if state['priv'] < 3 else '?'}-mode")


if __name__ == "__main__":
    main()
