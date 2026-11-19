# SPEC CPU 2026 under `perf stat` on the Nexys Video Linux (2026-11-15/16)

Three SPEC CPU 2026 benchmarks (777.zstd_r, 708.sqlite_r, 750.sealcrypto_r, `test` size, the static rv64gc binaries of `linux/spec/stage.py`) run on Wally's Linux
on the Nexys Video (`fpganexysvideo`, Vivado bitstream of 2026-10-20, 20 MHz, DDR3), each under `perf stat` with the 26 hardware counters of `linux/spec/events.py` plus
task-clock, page-faults, context-switches and cpu-migrations (`linux/spec/perf-run.sh`).  Every run ended with status 0 and printed the same output as SPEC's reference
(zstd) or the same output in both passes (sqlite).  Raw files: `/datos/tmp/spec-results/results1`, `results2`, `console.log` (outside git).

## Setup

- A new Buildroot image with perf (kernel 6.19.14) was written to the SD card from inside the running board, over the console UART (no card reader): `uart-upload.py`
  sent the GPT, firmware, DTB, kernel and the metadata of an ext4 partition (4, 8 GiB, label wallydata); `dd` wrote them; each piece was read back (page cache dropped) and
  its sha256 compared.  The GPT was written last.  The ZSBL then loaded the new kernel and Linux booted with perf.
- The benchmarks (4.3 MB) went to partition 4 the same way, file by file.  The kernel upload showed that the md5 of each chunk is not enough: one `cat /tmp/up.c >> ...` was
  lost on the UART and the final gzip had a CRC error; counting lines and comparing the md5 of prefixes of the file on the board located chunk 39, which was sent again.
- BusyBox `sh` on the board has no `$((...))` arithmetic: `perf-run.sh` uses `expr`.
- Writing to the SD through `mmc_spi` is slow (about 10 KB/s) and with dirty pages the kernel prints `soft lockup` warnings for minutes; the board stays alive.

## Results (counters summed over the runs of a benchmark; pass 1)

| benchmark | instr (M) | cycles (M) | CPI | br/instr % | dir MPKI | L1I MPKI | L1D MPKI | L1D miss % | load stall % | I$ stall % | wall time |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 708.sqlite_r | 2225.5 | 5246.2 | 2.36 | 13.4 | 13.77 | 19.70 | 12.71 | 3.4 | 3.2 | 22.8 | 317 s |
| 750.sealcrypto_r | 134602.0 | 205376.8 | 1.53 | 6.0 | 5.45 | 2.27 | 8.17 | 4.6 | 1.9 | 4.0 | 10928 s |
| 777.zstd_r | 2381.2 | 4284.8 | 1.80 | 9.4 | 6.08 | 5.27 | 10.54 | 2.8 | 2.3 | 8.0 | 264 s |

Second pass (sqlite, zstd): CPI 2.32 and 1.81, the MPKIs within a few percent (L1D MPKI of sqlite 11.7 against 12.7).  The instruction count differs by 1.5 % (sqlite)
and 2.7 % (zstd): the counters include the kernel's timer interrupts and, in zstd, a benchmark loop that runs for a fixed time (`-i1`).

## Limits

- Events 25 and 26 (branches and branch mispredictions, commit 8cb89bab9) are not in the October bitstream: they read 0, so the "mispred MPKI" column is empty.  A bitstream
  synthesized on 2026-11-15 from this branch was silent on the UART.  Cause (found with the ILA through Vivado's Hardware Manager, JTAG at 1 MHz, trigger
  `InstrValidM == 1`: the core ran, at PC 0 with a trap every cycle): `fpga/generator/Makefile` had `config := fpga$(board)`, evaluated before the target-specific `board`
  is set, so the ZSBL was built from `config/deriv/fpga` (EXT_MEM_RANGE 2 GiB) with its stack at 0xFFFFFFF8, outside the 512 MiB of DDR3: the first store faulted.
  `wsim fpganexysvideo --test fpga` shows it in simulation.  Fixed with `config = fpga$(board)`; the bitstream of 2026-11-16
  (`/datos/cvw-artifacts/nexysvideo-vivado-20261116-spec/`, slack +0.725 ns) boots and counts events 25 and 26; its results are in the section below.
- CPI at 20 MHz against DDR3 understates memory stalls; the MPKI columns do not depend on the clock.
- `test` size; sealcrypto takes 3 hours (four times that with the groups).  The other 20 benchmarks of the stage directory have not been run.

## The 2026-11-16 bitstream: `perf stat` with all counters livelocks

With the new bitstream the same `perf-run.sh` (26 counters plus cycles and instructions in one `perf stat`) never finished: the benchmark stayed in state R for
hours with no user time, 43,000 involuntary context switches, and a stack in `sifive_spi_transfer_one` (where it had been preempted: the SD is read by the task
itself).  What it is not: reverting the two EBU commits of 2026-11-09 (886b55244, 18538ff6d) and then the SPI commits of 2026-11-01/06 (663795a09, 60d1ded32)
and rebuilding did not change it; the SPI registers were idle (IP = 3, IE = 0, no interrupts).  What it is: the ILA of the design (no reprogramming, trigger
`InstrValidM`, PCs mapped with `addr2line` on the kernel's `vmlinux`) showed the core executing `__schedule`, `perf_event_task_sched_out`, `event_sched_in`,
`pmu_sbi_ctr_get_idx` and `__sbi_ecall` into OpenSBI.  Linux reprograms every event of a task through SBI at each context switch; with 28 events that costs more than
the task gets to run, so it is preempted again before executing an instruction.

| `perf stat` with | zstd | sqlite |
|---|---|---|
| no perf | 297 s | |
| 4 events | 177 s | |
| 15 events | | 1205 s (October bitstream, 26 events: 317 s) |
| 28 events (cycles, instructions, 26 counters) | does not finish | does not finish |
| 4 groups of 8 events (below) | 197-206 s per group | 239-244 s per group |

Why the same 26 events worked on the October bitstream is not known; there events 25 and 26 did not exist, which may have made two of the SBI calls cheap.

Fix: `perf-run.sh` runs each command once per group of `cycles`, `instructions` and six counters (`events.py`, `GROUPS`), and `report.py` takes every ratio inside one group.

## Results of the 2026-11-16 bitstream (four groups, pass 1, counters of group 1 for instructions and cycles)

| benchmark | instr (M) | cycles (M) | CPI | br/instr % | mispred MPKI | dir MPKI | L1I MPKI | L1D MPKI | L1D miss % | load stall % | I$ stall % |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 708.sqlite_r | 1788.4 | 4378.9 | 2.45 | 12.8 | 66.18 | 14.49 | 22.46 | 13.59 | 3.5 | 3.1 | 25.0 |
| 777.zstd_r | 2037.1 | 3632.4 | 1.78 | 8.3 | 24.40 | 5.36 | 4.61 | 11.08 | 2.9 | 1.9 | 7.1 |

All eight runs ended with status 0 and printed the same output as SPEC's reference (zstd) or the pass-1 output of the October run (sqlite).  The instruction counts of the
four groups agree within 0.4 % (sqlite 1783.7-1789.9 M, zstd 2017.4-2037.1 M).

- The instruction counts are 20 % (sqlite) and 15 % (zstd) lower than the October ones (2225.5 M and 2381.2 M) and the wall time per pass is lower (240 s against 317 s),
  while the rates that do not depend on the instruction count (direction MPKI 14.5 against 13.8, L1I and L1D misses per instruction within 10 %) are close.  The difference is most likely `perf`'s own
  context-switch work (SBI calls, scheduler) counted in the task's counters with 26 events in October: the October table overstated the instructions by that overhead.
- Branches: 18.7 % (sqlite) and 12.2 % (zstd) of the instructions are control transfers (r19 = r3 + r4 + r5 within 1 %).  The mispredicted ones are 66 per thousand
  instructions in sqlite and 24 in zstd (35 % and 20 % of the control transfers), and r1a is consistent with its parts (r7 direction 14.5 + r8 target 47.1 + r9 return stack 3.5 = 65.1 per thousand in sqlite).
  Most of the mispredictions are target mispredictions, not direction ones, so the BTB (1024 entries) and the indirect jumps matter more than the gshare predictor here.
  Counters r6 and r10 (any cause, instruction class) are larger than the sum of the parts (109 and 141 per thousand in sqlite); their meaning has not been checked.

## First pass of the other benchmarks (2026-11-17/18, `test` size, group 1 of the counters)

Eleven benchmarks are on the board (the 8 below plus zstd, sqlite and sealcrypto), uploaded over the UART (`upload-stage.sh`).  Each command ran once under `perf stat` with group 1
(cycles, instructions, branches, mispredictions), `PERF_GROUPS=1`; the output of every command that has a reference in SPEC's `data/test/output` passes SPEC's `specdiff`
(flightdm with its own tolerances: `--abstol 0.09` and `0.01`, `--coterminal_angles`).  Raw files: `/datos/tmp/spec-results/results4`, `results5` (outside git).

| benchmark | instr (M) | cycles (M) | CPI | br/instr % | mispred MPKI | dir MPKI | wall time | output |
|---|---|---|---|---|---|---|---|---|
| 707.ntest_r | 3316.9 | 5997.0 | 1.81 | 9.8 | 31.72 | 7.37 | 352 s | specdiff ok |
| 709.cactus_r | 68346.2 | 271643.8 | 3.97 | 2.2 | 19.80 | 1.25 | 13960 s | specdiff ok |
| 710.omnetpp_r (3 runs) | 2777.1 | 8044.2 | 2.90 | 13.8 | 68.33 | 13.62 | 336 + 375 + 8 s | specdiff ok (runs 2, 3) |
| 727.cppcheck_r | 61.3 | 149.3 | 2.44 | 15.5 | 66.95 | 18.43 | 10 s | specdiff ok |
| 748.flightdm_r (2 runs) | 25383.2 | 85739.9 | 3.38 | 10.7 | 60.79 | 12.52 | 666 + 3904 s | specdiff ok |
| 767.nest_r (2 runs) | 45301.7 | 68383.0 | 1.51 | 13.8 | 20.80 | 4.08 | 802 + 2953 s | specdiff ok |

- Do not fit in the 512 MiB of the board: 782.lbm_r (`could not allocate 817.9 MByte`, 1 s) and 749.fotonik3d_r (killed by the OOM killer with 465 MB resident after 6662 s of paging, `rc=137`).
  The first fotonik3d run of 106 s with `rc=0` had no input: `stage.py` did not decompress `OBJ-values.dat.xz`, and the program printed `Failed to open file OBJ-values.dat` and still exited with 0 (so `rc` alone is not a check).
- Two bugs of `stage.py` found by `specdiff`/the output: omnetpp is invoked as `-f <ini> -c <configuration>` (it was staged as `<ini> <configuration> 0`: `Cannot open ini file 'General'`), and cppcheck needs `--platform=unix64`
  (its test-size `testrunner_r` run is not staged).  `control_fixup` and the decompression of the `.xz` inputs (fotonik3d, vpr, gem5) fix both.
- Instruction counts against NEMU (xiangshan-04, same binaries and inputs, application = total - 274 M of boot): the board counts 7-22 % more in the long runs (cactus 68.3 G against 56.2 G,
  ntest 3.32 against 2.90, flightdm 3.58 against 2.87, nest 40.9 against 38.3).  The difference grows with the run time, about 3.5-4.5 thousand instructions per timer tick (`HZ=250`: SBI timer
  call, kernel tick), and in short runs with I/O it is the SD card read by the task itself with the SPI driver polling (`perf-run.sh` now reads the files once before measuring).
  For tiny runs NEMU's number is not usable (its boot count depends on the initramfs size).
- Speed: cactus 56.2 G instructions in 13,960 s is 4.0 M instructions per second (CPI 3.97 at 20 MHz); ntest 8-9 M/s, nest 13 M/s in its long run.
- The cache columns (groups 2-4) were measured afterwards: next section.

## All four counter groups (2026-11-18/19)

Groups 2-4 of the eight benchmarks ran on the board unattended (`PERF_SKIP=1`, about 19 h; cactus alone took 3.8 h per group), then the first group of cppcheck, ntest and omnetpp
again (the first run predates the warm-up read of the inputs).  All 40 runs ended with `rc=0` and print the same output in the four groups.  Counters of the four groups (`report.py`,
instructions and cycles of group 1, every ratio inside one group; raw files `/datos/tmp/spec-results/all`, outside git):

| benchmark | instr (M) | cycles (M) | CPI | br/instr % | mispred MPKI | dir MPKI | L1I MPKI | L1D MPKI | L1D miss % | load stall % | I$ stall % |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 707.ntest_r | 3313.0 | 5951.4 | 1.80 | 9.8 | 31.52 | 7.25 | 6.00 | 12.67 | 4.7 | 2.6 | 9.3 |
| 709.cactus_r | 68346.2 | 271643.8 | 3.97 | 2.2 | 19.80 | 1.25 | 49.06 | 43.58 | 10.6 | 1.3 | 34.2 |
| 710.omnetpp_r (3 runs) | 2900.3 | 8429.4 | 2.91 | 13.8 | 68.28 | 13.61 | 24.66 | 13.02 | 3.0 | 3.1 | 23.7 |
| 727.cppcheck_r | 60.8 | 147.7 | 2.43 | 15.5 | 67.00 | 18.45 | 18.63 | 13.74 | 3.8 | 2.7 | 21.2 |
| 748.flightdm_r (2 runs) | 25383.2 | 85739.9 | 3.38 | 10.7 | 60.79 | 12.52 | 26.60 | 38.43 | 8.7 | 2.5 | 21.2 |
| 767.nest_r (2 runs) | 45301.7 | 68383.0 | 1.51 | 13.8 | 20.80 | 4.08 | 4.40 | 5.91 | 2.1 | 2.4 | 7.9 |

How far the groups agree (instructions of the same command in each group, M, and wall time; the program does the same work every time):

| run | g1 | g2 | g3 | g4 | spread |
|---|---|---|---|---|---|
| cactus | 68346 / 13960 s | 67794 / 13784 s | 67899 / 13822 s | 67839 / 13741 s | 1 % |
| nest run 2 | 40912 / 2953 s | 40727 / 2920 s | 40700 / 2918 s | 40661 / 2878 s | 1 % |
| flightdm run 2 | 21805 / 3904 s | 21436 / 3777 s | 21506 / 3863 s | 21527 / 3763 s | 2 % |
| ntest | 3313 / 349 s | 3104 / 290 s | 3138 / 301 s | 3146 / 301 s | 7 % |
| flightdm run 1 | 3578 / 666 s | 3302 / 586 s | 3339 / 596 s | 3327 / 597 s | 8 % |
| nest run 1 | 4390 / 802 s | 3908 / 653 s | 3948 / 665 s | 4012 / 683 s | 12 % |
| omnetpp run 1 | 1619 / 414 s | 1467 / 350 s | 2290 / 565 s | 2262 / 557 s | 56 % |
| omnetpp run 2 | 1218 / 338 s | 57 / 9 s | 1133 / 298 s | 58 / 9 s | 20x |
| omnetpp run 3 | 63 / 10 s | 63 / 9 s | 206 / 48 s | 448 / 115 s | 7x |
| cppcheck | 61 / 10 s | 60 / 9 s | 60 / 10 s | 261 / 66 s | 4x |

- The long runs are reproducible to 1-2 %.  Group 1 is 6-12 % above the others in the runs of a few hundred seconds, also after repeating it with the inputs already in the page cache; not explained.
- The short runs of omnetpp and cppcheck are not reproducible: the same command with the same output (omnetpp's OneFifo is 206 events) takes 9 s or 338 s, with the instruction count following the time
  (3.6 M instructions per second while it runs, so the task is executing, not waiting).  The ratios of the long runs are not affected, but the short runs' rows carry this noise and the
  `report.py` note "instructions differ N % between groups" marks them.  A possible cause, not tested: the console log of the whole run shows 138 `soft lockup` reports in kernel workers
  and the stacks of `mmc_rescan` and `mmc_sd_detect` (the kernel polls the SD card for its presence), so the SD card's SPI polling may take the CPU and the counters in some runs.
  Next try: mark the card `non-removable` in the device tree (no polling) and repeat a short run several times.
- Whether a counter ratio is trustworthy therefore needs the spread of the instructions across groups next to it (the table above); use cactus, nest and flightdm run 2 as the clean data.

## Next

1. ~~The UART~~ (done 2026-11-17, not an RTL fault).  Test: `stty raw -echo; head -c 20000 > file` on the console, 20,000 random bytes sent from the PC, md5 and
   `/proc/tty/driver/serial` compared.  Up to 8 bytes per millisecond (7.4 KB/s, 65 % of the 115200-baud line rate) nothing is lost (bursts of 2, 8 and 16; also with the tty
   cooked and echoing, 2 x 40 KB).  Sent without pauses (line rate) there are 9-12 overruns (`oe`, no `fe`/`pe`) per 20 KB.  Lowering the RX trigger level by writing FCR
   (8 -> 4 -> 1) gives 12, 9 and 5 per 20 KB, and the UART interrupt count stays at about 1800 per 20,000 characters (about 11 characters per interrupt): the 20 MHz core
   spends about one character time (87 us, roughly 1700 cycles) per character in the 8250 driver and the tty layer, so at line rate it is saturated and the 16-byte FIFO
   overflows now and then.  The "doubled characters" seen before did not reproduce.  `uart-upload.py` now sends 8 bytes per millisecond (it was 2): 232 KB in 123 s, 0 retries.
2. More benchmarks, the `train` size where it fits, and the same counters in simulation.
3. Why a context switch under `perf` costs more than in October (measured 2026-11-17, partly answered).  Test: `dd bs=512 count=2000 | dd` (a pipe, about 4000 context switches)
   under `perf stat -e <N events>`, wall time of the pipeline on the board, two repeats:

   | bitstream | no perf | 2 events | 8 events | 24 events |
   |---|---|---|---|---|
   | 2026-10-20 (October) | 3.2 s | 4.2 s | 4.4 s | 5.9 s |
   | 2026-11-16 | 2.5 s | 4.5 s | 4.3 s | 8.0 s |
   | 2026-11-16, EBU commits reverted | 3.3 s | 4.0 s | 4.5 s | 7.6 s |
   | 2026-11-16, SPI commits reverted | 2.8 s | 3.7 s | 4.3 s | 6.8 s |

   The cost grows linearly with the number of events and does not depend on which counters (8 events in r3-r8, r13-r18 or r19-r1a: the same 4.0-4.7 s), so it is per event and per
   context switch (about 40 us, 800 cycles, per event on the new bitstream; 2.5 times the October slope: 0.23 s per event against 0.09 s).  With `HZ=250` (4 ms tick) 28 events
   plus the cold caches after a switch are enough to exceed the tick in the real benchmark.  Without `perf` the new bitstream is not slower.  Reverting the EBU commits does not
   restore the October slope; the SPI revert is in between and within the noise (+-0.5 s), so no single commit is identified.  What is left: the CSR/SBI path (`mhpmevent`
   and counter writes through OpenSBI, `pmucountercontrol`), whose RTL changed between the two builds (events 25/26, counter control).  To find it, measure the cycles of one
   `sbi_pmu_counter_config_matching` call (a bare-metal loop in M mode, or the ILA with a trigger on the ecall).

   Parked (2026-11-17); the groups of six counters avoid the problem.  Ruled out so far:
   - The configuration: the effective `fpganexysvideo` parameters of the two builds (82d0b80f7 and 2a0c6f659, `derivgen.pl` in a worktree) differ only in options that are
     off and in `BIGENDIAN_SUPPORTED` 1 -> 0 (add5053df, upstream: rv64gc little-endian only until Sail and ACT can test big-endian; Linux never uses it).
   - Both bitstreams were built with Vivado 2024.2 at 20 MHz (not the open flow).
   - OpenSBI: ILA captures from a kernel `ecall` (24 events under `perf` in a loop) give the same CPI (1.2-1.5) and the same instruction count (short calls about 500 instructions,
     660 cycles) on both bitstreams.
   - Extra traps: 30 traps captured on each bitstream have the same mix (15-16 kernel `ecall`, 9-10 syscalls, the rest interrupts); no `hpmcounter` read traps to OpenSBI.
   Still open: the number of SBI calls per context switch, or the kernel code between them.  Next: count kernel `ecall`s per second (ILA in count mode), or time `__schedule` to the
   return to user mode on both bitstreams.  Scripts (outside git): `ila5.tcl` (trigger on ecall), `ila6.tcl` (trigger on TrapM), `sbi.py`, `traps.py` in the session scratchpad.
