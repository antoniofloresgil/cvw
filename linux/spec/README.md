# SPEC CPU 2026 under `perf stat` on Wally Linux

Measure the performance of Wally running Linux, first on the FPGA and later also in simulation, with its fixed-function HPM counters through `perf stat` (the SBI PMU, see [../pmu](../pmu/README.md)).
Use the **Vivado** flow (`make nexysvideo` in `fpga/generator`, `fpganexysvideo`, 20 MHz, 32 counters): the board image must have a kernel with
`PERF_EVENTS` and `RISCV_PMU_SBI`, the PMU device-tree node (`wally-pmu.dtsi`) and `perf` (Buildroot's `wally_defconfig` selects it; not checked on the board yet).

The SPEC CPU 2026 benchmarks and inputs are not in this repository and must not be: SPEC CPU 2026 belongs to its licensees. `stage.py` only reads an installation
and writes a staging directory outside git; `perf-run.sh` and `report.py` hold no SPEC content.

1. On the PC, with the installation (read only) of the built rv64gc static executables:
   `./stage.py --spec <cpu2026_install> --size test --out /datos/tmp/spec-stage [--bench 782.lbm_r ...]`
   makes `<out>/<benchmark>/` (stripped executable, inputs of `data/all` and `data/<size>`, `cmds`), `<out>/events` and `<out>/perf-run.sh`.
   Benchmarks whose `invoke` it does not understand (control files, `<name>.in`, no arguments are) are listed and skipped.
2. Copy `<out>` to the board's SD card (the benchmarks you choose; check their memory against the 512 MiB first). For a small benchmark without
   touching the card, `uart-upload.py` puts a file on the running Linux through the console UART (verified chunks, about 2.5 KB/s of compressed data, see its header); `upload-stage.sh` does it for whole benchmark directories (the board has no `tar`, so `untar.sh` extracts them, and the md5 of every file is checked on the board). The console loses characters while a benchmark runs: upload and fetch results with the board idle.
3. `PERF_GROUPS=1` in front of the command runs only the first group of counters (a first pass: does it start, fit in memory, give the right output?). On the board, as root, idle: `sh perf-run.sh <out on the board> /root/results [benchmark ...]`: every command runs once per line of `<out>/events`
   (four groups of `cycles,instructions` and six counters, `events.py`) under `perf stat -x,`, one CSV per run and group. The groups are separate runs because
   Linux reprograms all of a task's events through SBI at every context switch: with all 26 counters at once a benchmark stops making progress on the board
   (see `docs/engineering/experiments/2026-11-16-spec-perf-on-board.md`). So a benchmark takes four times as long; each counter has its own hardware counter, so none is multiplexed.
4. Copy `results` back and run `./report.py results`: a table with CPI and the clock-independent rates; every ratio is taken inside one group,
   and `report.py` notes when the instruction counts of the groups differ by more than 5 %.

Reading the numbers: counters include M, S and U mode (no `:u` filter in the base configuration), and the timer interrupt and page faults of the benchmark are in them.
At 20 MHz against DDR3 a cache miss costs few core cycles, so CPI understates the memory stalls of a fast chip: compare the misses and mispredictions per thousand
instructions (MPKI), which do not depend on the clock. Counter meanings: `events.py` (from `src/privileged/pmuevents.sv`).
