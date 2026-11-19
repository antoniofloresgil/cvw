# Checkpoints for sampled simulation (SimPoint) of Wally's Linux

Goal: simulate only a few representative intervals of a SPEC benchmark on Wally (RTL simulation), each started from a
checkpoint of the whole machine, and weight their results, instead of the whole run (the FPGA runs the `test` inputs in
hours; the RTL simulator would need weeks).  The method is SimPoint's, as in XiangShan's flow (NEMU, `gcpt` restore);
here the functional model is QEMU's `virt` machine, whose memory map Wally's Linux already supports (`../qemuBoot.sh`).

Steps (status):
1. **Profile** (done, `profile.sh`): basic block vectors of the benchmark's region of interest, SimPoint's intervals and weights.
2. **Checkpoint** (done, `checkpoint.sh`): QEMU stops at the first instruction of each chosen interval and saves the
   hart's state, the device registers and the RAM; `mkrestore.py` makes the restore program.
3. **Restore** (runs; measurement to do): Wally starts from the RAM image and the restore program, which loads the
   state (registers, CSRs, CLINT, PLIC, UART) and returns to the interrupted code; to do: warm-up, then the interval,
   counted by the HPM counters, read at the end of the simulation.
4. **Weight** (to do): CPI and the other rates of the intervals weighted by SimPoint; validated against a full `test`
   run on the FPGA.

## Profile

```
IMAGES=<Buildroot images> ./profile.sh <stage dir> <benchmark> <out dir> [interval] [maxK]
```

QEMU and SimPoint 3.2 come from the tool chain installation (`bin/installation/qemu-install.sh`,
`bin/installation/simpoint-install.sh`, both into `$RISCV/bin`); `SIMPOINT` and `QEMU` select other binaries.

`<stage dir>` is the output of `../spec/stage.py`.  QEMU boots `fw_jump.bin` and `Image` with `wally-virt.dts` and
deterministic time (`-icount shift=0,sleep=off`), so the same run executes the same instructions every time.  The
initrd is built byte for byte the same every time (stripped markers, fixed dates and order, `cpio --reproducible`):
with only its metadata different, Linux ran 265 K more instructions before the region and SimPoint chose other points.  The
benchmark comes in an initrd that Linux unpacks over the built-in root file system (the kernel has no virtio or 9p), with
`/etc/init.d/S99spec`, which runs the benchmark's commands between `roi-start` and `roi-end`.  Those two programs execute
a HINT instruction each (`slti x0, x0, 0x7a1` and `0x7a2`), a no-op on any RISC-V core, Wally included.  The QEMU plugin
`roibbv.c` (written for this, no QEMU code) counts basic blocks (start address and length: the same address can start
blocks of other lengths, in another process or when QEMU translates a shorter block there) only between the two, writes one SimPoint frequency
vector per interval, prints the instruction count since boot at both markers, and stops QEMU at the end (the virt
machine cannot be powered off with Wally's device tree: `poweroff` spins in the kernel).  Kernel code that runs during
the region (system calls, page faults, timer interrupts) is part of the vectors, as it is part of what Wally executes.

First results (2026-11-19, `test` inputs, the SPEC Buildroot image, QEMU 11.0.2, SimPoint 3.2 with maxK 30):

| benchmark | instructions in the region | interval | intervals | SimPoint points | time |
|---|---|---|---|---|---|
| 727.cppcheck_r | 50.7 M | 1 M | 51 | 8 | 2 s |
| 777.zstd_r | 1845 M | 10 M | 185 | 8 | 3 s |
| 707.ntest_r | 2771 M | 10 M | 277 | 11 | 4 s |

Boot to the region: 200-216 M instructions.  The number of points is not stable: SimPoint picks K by a BIC threshold,
and small changes in the vectors (an initrd that differed only in metadata, the block length fix) gave 12, 28 and 29
or 8, 14 and 11 points; the weighted result, not the set of points, is what step 4 has to validate.  The program's
output is the same as on the board (cppcheck's `hello_bogey.txt`).  Open: ntest counts 2.77 G instructions here
(2.54 G before the block length fix), 2.90 G in NEMU (XiangShan's flow) and 3.1-3.3 G with `perf` on the board; the
regions are not delimited in the same way, not yet compared.

## Checkpoint and restore

```
IMAGES=<Buildroot images> ./checkpoint.sh <profile out dir> <checkpoint dir> [warm-up instructions]
wsim buildroot buildroot --sim verilator --args "+LinuxRam=<dir>/<k>/ram.bin +LinuxBootmem=<dir>/<k>/bootmem.bin +INSTR_LIMIT=<n>"
```

QEMU boots the profile's initrd and device tree again, so it executes the same instructions, with the plugin
`roickpt.c`, which counts as `roibbv.c` does and, at the start of each chosen interval (warm-up instructions earlier,
and at the first block outside M-mode: never inside OpenSBI), writes `<k>/ram.bin` (the 256 MiB RAM in the
testbench's byte order, as `../Makefile` makes the boot testvectors), `<k>/state.txt` (the registers and CSRs QEMU
describes to GDB, the privilege mode, the CLINT, PLIC and UART registers) and `<k>/info.txt` (counts, SimPoint weight).
`mkrestore.py` turns `state.txt` into `bootmem.bin`, the BOOTROM at 0x1000 from which the `buildroot` configuration
starts: about 2 KiB of M-mode code and data that restore the floating-point registers, PMP, the trap delegation and
S-mode CSRs, `satp`, the CLINT, PLIC and UART registers, then `mstatus` (MPP = the interrupted mode), `mepc` = pc,
OpenSBI's `mtvec`, the integer registers, and `mret`.  OpenSBI's state is in the RAM image, so later SBI calls work.
On purpose not restored: the counters (`mcycle`, `minstret`, `mhpmcounter3-31` start at 0, `mcountinhibit` is 0 and
`mhpmevent3-31` 1, so `INSTR_LIMIT` and every HPM counter count from the restore) and `stimecmp`, which QEMU does not
expose to plugins: it is set to the restored `mtime`, so the kernel takes one early timer interrupt and programs the
next one itself.  OpenSBI in QEMU found the same extensions as on the board (`sstc,zicntr,zihpm,zicboz,zicbom,svpbmt,
svade,svadu`); it uses 16 HPM counters there, a subset of Wally's 29.

First runs (2026-11-19, Verilator, `buildroot` configuration, about 100 K instructions per second): cppcheck's
checkpoint 50 (in the kernel, 0.7 M instructions before the end of the region) and 47 (in the program, 3.7 M before)
run on Wally to the end of the program, which prints `@@SPEC-CMD 1 rc=0`, and Linux goes on to the shell.
