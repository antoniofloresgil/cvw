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

## Next

1. ~~The UART~~ (done 2026-11-17, not an RTL fault).  Test: `stty raw -echo; head -c 20000 > file` on the console, 20,000 random bytes sent from the PC, md5 and
   `/proc/tty/driver/serial` compared.  Up to 8 bytes per millisecond (7.4 KB/s, 65 % of the 115200-baud line rate) nothing is lost (bursts of 2, 8 and 16; also with the tty
   cooked and echoing, 2 x 40 KB).  Sent without pauses (line rate) there are 9-12 overruns (`oe`, no `fe`/`pe`) per 20 KB.  Lowering the RX trigger level by writing FCR
   (8 -> 4 -> 1) gives 12, 9 and 5 per 20 KB, and the UART interrupt count stays at about 1800 per 20,000 characters (about 11 characters per interrupt): the 20 MHz core
   spends about one character time (87 us, roughly 1700 cycles) per character in the 8250 driver and the tty layer, so at line rate it is saturated and the 16-byte FIFO
   overflows now and then.  The "doubled characters" seen before did not reproduce.  `uart-upload.py` now sends 8 bytes per millisecond (it was 2): 232 KB in 123 s, 0 retries.
2. More benchmarks, the `train` size where it fits, and the same counters in simulation.
3. Why a context switch under `perf` costs so much more on this bitstream (SBI path in OpenSBI, or the core): measure the cycles of one `sbi_pmu_counter_config_matching` call.
