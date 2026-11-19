# Checkpoints for sampled simulation (SimPoint) of Wally's Linux

Goal: simulate only a few representative intervals of a SPEC benchmark on Wally (RTL simulation), each started from a
checkpoint of the whole machine, and weight their results, instead of the whole run (the FPGA runs the `test` inputs in
hours; the RTL simulator would need weeks).  The method is SimPoint's, as in XiangShan's flow (NEMU, `gcpt` restore);
here the functional model is QEMU's `virt` machine, whose memory map Wally's Linux already supports (`../qemuBoot.sh`).

Steps (status):
1. **Profile** (done, `profile.sh`): basic block vectors of the benchmark's region of interest, SimPoint's intervals and weights.
2. **Checkpoint** (to do): QEMU stops at the first instruction of each chosen interval and saves the hart's state and the RAM.
3. **Restore** (to do): Wally starts from the RAM image and a small restore program that loads the state (registers,
   CSRs, timer) and returns to the interrupted code; warm-up, then the interval, counted by the HPM counters.
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
`roibbv.c` (written for this, no QEMU code) counts basic blocks only between the two, writes one SimPoint frequency
vector per interval, prints the instruction count since boot at both markers, and stops QEMU at the end (the virt
machine cannot be powered off with Wally's device tree: `poweroff` spins in the kernel).  Kernel code that runs during
the region (system calls, page faults, timer interrupts) is part of the vectors, as it is part of what Wally executes.

First results (2026-11-19, `test` inputs, the SPEC Buildroot image, QEMU 11.0.2, SimPoint 3.2 with maxK 30):

| benchmark | instructions in the region | interval | intervals | SimPoint points | time |
|---|---|---|---|---|---|
| 727.cppcheck_r | 50.7 M | 1 M | 51 | 8 | 2 s |
| 777.zstd_r | 1653 M | 10 M | 165 | 14 | 3 s |
| 707.ntest_r | 2538 M | 10 M | 254 | 11 | 4 s |

Boot to the region: 200-216 M instructions.  The number of points is not stable: SimPoint picks K by a BIC threshold,
and the vectors of a run whose initrd differed only in metadata gave 12, 28 and 29 points; the weighted result, not
the set of points, is what step 4 has to validate.  The program's output is the same as on the board (cppcheck's
`hello_bogey.txt`).  Open: ntest counts 2.54 G instructions here, 2.90 G in NEMU (XiangShan's flow) and 3.1-3.3 G with
`perf` on the board; the regions are not delimited in the same way, not yet compared.
