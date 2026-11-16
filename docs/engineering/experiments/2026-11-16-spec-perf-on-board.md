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
  (`/datos/cvw-artifacts/nexysvideo-vivado-20261116-spec/`, slack +0.725 ns) boots and counts events 25 and 26.  The same benchmarks were run again with it
  (results3 and results4 on the board; the table is to be added here).
- CPI at 20 MHz against DDR3 understates memory stalls; the MPKI columns do not depend on the clock.
- `test` size; sealcrypto takes 3 hours.  The other 20 benchmarks of the stage directory have not been run.

## Next

1. Add the results of the 2026-11-16 bitstream (the branch counters).
2. `/proc/tty/driver/serial` showed `oe:46` (overruns) after 14 MB received at 2 bytes per millisecond: the UART has 16-byte FIFOs and Linux detects a 16550A, so
   see why characters are still lost (interrupt latency, the RX FIFO in `uartPC16550D.sv`, or the host side).
3. More benchmarks, the `train` size where it fits, and the same counters in simulation.
