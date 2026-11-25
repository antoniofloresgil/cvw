# Checkpoints for sampled simulation (SimPoint) of Wally's Linux

Goal: simulate only a few representative intervals of a SPEC benchmark on Wally (RTL simulation), each started from a
checkpoint of the whole machine, and weight their results, instead of the whole run (the FPGA runs the `test` inputs in
hours; the RTL simulator would need weeks).  The method is SimPoint's, as in XiangShan's flow (NEMU, `gcpt` restore);
here the functional model is QEMU's `virt` machine, whose memory map Wally's Linux already supports (`../qemuBoot.sh`).

Steps (status):
1. **Profile** (done, `profile.sh`): basic block vectors of the benchmark's region of interest, SimPoint's intervals and weights.
2. **Checkpoint** (done, `checkpoint.sh`): QEMU stops at the first instruction of each chosen interval and saves the
   hart's state, the device registers and the RAM; `mkrestore.py` makes the restore program.
3. **Restore** (done): Wally starts from the RAM image and the restore program, which loads the state (registers,
   CSRs, CLINT, PLIC, UART) and returns to the interrupted code; warm-up, then the interval, counted by the HPM counters.
   The same checkpoint also starts the FPGA board from its SD card (`sdimage.py`, below; not yet tried on the board).
4. **Weight** (done, `measure.py`; validated on cppcheck against the whole region simulated on Wally): CPI and the
   other rates of the intervals weighted by SimPoint.  To do: the larger benchmarks, and a comparison with the FPGA.

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
`mhpmevent3-31` 1, so `INSTR_LIMIT` and every HPM counter count from the restore).  QEMU does not expose `stimecmp`
to plugins: `roickpt.c` runs on after the last checkpoint to the first supervisor timer interrupt, when `mtime` has just
reached `stimecmp`, and appends that `mtime` to each pending `state.txt` as `stimecmp` (checkpoints without it get the
restored `mtime`, so the kernel takes one early timer interrupt and programs the next one itself).  OpenSBI in QEMU found the same extensions as on the board (`sstc,zicntr,zihpm,zicboz,zicbom,svpbmt,
svade,svadu`); it uses 16 HPM counters there, a subset of Wally's 29.

First runs (2026-11-19, Verilator, `buildroot` configuration, about 100 K instructions per second): cppcheck's
checkpoint 50 (in the kernel, 0.7 M instructions before the end of the region) and 47 (in the program, 3.7 M before)
run on Wally to the end of the program, which prints `@@SPEC-CMD 1 rc=0`, and Linux goes on to the shell.

## Measure and weight

```
./measure.py <checkpoint dir> [--jobs N] [--reference <wsim log of the whole region>]
./summary.py <WROOT> <benchmark>... [--suffix -A] [--markdown]     # a whole campaign in one table, runs nothing
```

Each checkpoint runs on Wally with `+INSTR_LIMIT=<warm-up + interval>` and `+HPM_WARMUP=<warm-up>`; the testbench
prints every counter (`HPM <minstret> <counter 0> ...`) at the end of the warm-up and at the limit (and every
`+HPM_PERIOD` instructions), and the difference is the interval's count (`<k>/hpm.txt`).  The weighted CPI estimates
the region's, as the intervals are equally long.

Validation on 727.cppcheck_r (2026-11-19, 1 M intervals, 8 points; Verilator): the whole region simulated on Wally from
its start (checkpoint of interval 0, `+HPM_PERIOD=1000000`, 50.5 M instructions, 400 s) has a CPI of 1.641; the
weighted points give 1.643 without warm-up, 1.640 with 100 K instructions of warm-up and 1.650 with 300 K (each point
about 10 s of simulation).  The events per thousand instructions agree as well (branch mispredictions 104.4 against
103.5, D-cache misses 10.7 against 11.0).  Single points differ more from the same interval in the whole run (CPI
1.736 against 1.630 for interval 17): Wally counts the intervals from the restore with `minstret`, QEMU at block
granularity, and the kernel runs other instructions on Wally (timer interrupts come at other points, as time follows
cycles), so the windows drift apart along the region; the weighted sum averages that out.  With L1 caches only and
1 M intervals the warm-up hardly matters; with 10 M intervals neither (777.zstd_r: weighted CPI 1.347 without warm-up,
1.348 with 1 M).

## On the FPGA board

```
./sdimage.py <checkpoint dir>/<k> <image>          # about 257 MiB, 2 s
sudo dd if=<image> of=/dev/sdX bs=4M conv=fsync status=progress
```

The board's ZSBL (`fpga/zsbl`) and bitstream stay as they are: the ZSBL loads the card's first three GPT partitions,
the first at the top of the DDR3 less 16 MiB (`FDT_ADDRESS`), the second at 0x80000000, the third at 0x80200000, and
jumps to 0x80000000.  `sdimage.py` puts there the restore program (`mkrestore.py --fpga`, linked at `FDT_ADDRESS`:
0x9F000000 for `fpganexysvideo`), the whole RAM in plain byte order with its first doubleword replaced by
`auipc t0, ...; jr t0` to the restore program, which writes it back and executes `fence.i`, and one block of the same RAM.
The restore program is the simulator's with three changes: that doubleword, the UART's divisor for 115200 baud with
the board's clock (`--sysclock`, 20 MHz for the Vivado build; in QEMU the console runs at 9600 baud, as `wally-virt.dts`
gives no speed, which on the board would slow down every message the kernel prints), and a receive FIFO that
interrupts on every character instead of Linux's 8 of 16 (the board loses typed characters otherwise while a benchmark
runs; the driver writes the FCR again only when the line settings change).  The ZSBL reads the RAM through SPI at
10 MHz, about 7.5 minutes.  On the board `mtime` counts at the board's clock while the kernel's device tree
says 30 MHz, so Linux's time runs slower than real time; the timer ticks come further apart.  The HPM counters start
at 0 at the restore as in simulation, but nothing stops the board after a given number of instructions.

Tried on 2026-11-23 with point 47 of 727.cppcheck_r (mode A checkpoints) on the Nexys Video, Vivado build of
`fpganexysvideo` at 20 MHz: the ZSBL loaded the card in 453 s, the restore program returned to the checkpoint, the
benchmark ended with `@@SPEC-CMD 1 rc=0`, its `hello_bogey.txt` has the md5 of SPEC's reference output, and Linux went
on to its shell with no receive overrun on the console.  If the board shows Digilent's demo instead of the ZSBL, the
FPGA has lost its configuration: load the bitstream again (`openFPGALoader -b nexysVideo <fpgaTop.bit>`), which also
starts the ZSBL.

## Time

Wally's CLINT advances `mtime` once per cycle, while the device tree gives Linux a 30 MHz timebase, so with `HZ=250`
a timer tick comes about every 97 K instructions.  In QEMU's `virt` machine with `-icount shift=0`, `mtime` (10 MHz)
advances once per 100 instructions, so a tick comes every 12 M instructions.  Started from a QEMU checkpoint, Wally
therefore runs about 3 % more instructions (the kernel's tick handler), and its intervals drift away from QEMU's
along the region.  The ticks also cost about 5.5 % of the CPI and most of the I-cache misses (727.cppcheck_r).
`drift.py` finds where the two part: it compares QEMU's PC trace (`checkpoint.sh` with `TRACE=<n>`) with the
testbench's (`+PC_TRACE=<file>`).

Two remedies were compared on 727.cppcheck_r, 777.zstd_r and 707.ntest_r, each against the whole region simulated the
same way:

- **A, time follows the instructions** (`measure.py --time-insns 100`, testbench `+MTIME_INSNS=100
  +MTIME_BASE=<the checkpoint's mtime>`, `stimecmp` from `roickpt`): Wally takes the timer interrupts where QEMU did.
- **B, no timer interrupts in the region** (`NOTIMER=1` for `profile.sh` and `checkpoint.sh`): this is what XiangShan's
  NEMU does before the workload.

Results:

- Each checkpoint reproduces its interval of the whole run within 0.6 % of CPI in both.
- The weighted CPI is off the region's by a mean of 1.0 % with A (−1.2 %, −0.8 %, +1.0 %) and by 1.6 % with B
  (+3.8 %, −0.5 %, −0.6 %).  What remains is SimPoint's sampling error.
- B's 707.ntest_r checkpoints miss 4.7 % fewer D-cache lines than their intervals.
- The region's CPI hardly differs between A and B (0.3 %).

A stays: it is slightly closer, and it keeps the system as it is.  A warm-up of 1 M instructions changes nothing
with 10 M intervals.

## On the cluster

```
IMAGES=<Buildroot images> ./prepare.sh <stage dir> <benchmark>     # profile, checkpoints, start of the region
cluster/cluster.sh image                                           # once: the Apptainer image
cluster/cluster.sh build                                           # once per change of the RTL or the testbench
cluster/cluster.sh submit <benchmark>...                           # SimPoint's points, an array of 1-CPU tasks
cluster/cluster.sh reference <benchmark>...                        # the whole region, one task each
cluster/cluster.sh fetch <benchmark> <benchmark>-ref               # the logs back; measure.py reads them
```

`prepare.sh` writes the checkpoints of `<benchmark>` and of `<benchmark>-ref` (the start of the region) under one
directory (`WROOT`); `SUFFIX=-A` writes another set, `<benchmark>-A` and `<benchmark>-A-ref`, from the same profile.
With `MTIME=100`, `submit` and `reference` run with time following the instructions (mode A above); measure the
fetched logs with `measure.py --time-insns 100`.  The cluster's nodes reach it through a read-only key (`rrsync -ro` in the PC's
`authorized_keys`): each task copies only its own `ram.bin`, `bootmem.bin` and `info.txt` to the node's local disk
(up to 8 tries with a random pause: the PC's `sshd` refuses connections when many tasks start together), runs the
simulator, copies back `wsim.log`, `uart.out` and `time.log`, and deletes the checkpoint, so the SPEC data stay on
the PC.  The cluster's hosts have no Verilator and an old C library: the simulator is built and run inside
Verilator's own Docker image of the PC's version (5.036), pulled by digest into Apptainer.  A task's verdict is the
testbench's counter line at the instruction limit, not its exit code or Slurm's state.  The nodes' address for the PC
is not in the repository (`PC`, or `~/.wally-cluster-pc`).

A checkpoint run on a node gives the same counters as on the PC, bit for bit (777.zstd_r, interval 35); a node
simulates about 66 K instructions per second (the PC 110-170 K), and a simulation needs 270 MB.  `INSTR_LIMIT` (and
`HPM_WARMUP`, `HPM_PERIOD`) are 64-bit: a whole region can be longer than 2^31 instructions.
