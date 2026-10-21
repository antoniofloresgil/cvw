# Smcdeleg/Ssccfg counter delegation check

Date: 2026-10-21. Branch: `adding-mpu-support`, working tree above
`776ae473b`. Configurations: RV32/RV64 base and derived
`smcdeleg_*`/`pmu_deleg_*` targets. Question: do delegated supervisor
aliases and `scountinhibit` work without changing the base PMU behavior?

## Reproduction and verdict

After `source ./setup.sh` and `make deriv`:

```sh
PATH=/opt/riscv/bin:$PATH WALLY=$PWD python3 tests/pmu/run.py --work /tmp/cvw-smcdeleg-pmu
```

**PASS:** 22 directed Verilator cases, including RV32/RV64 with delegation
off/on, Sscofpmf and Smcntrpmf combinations, all board DTB builds and PMU
event-map checks. The cases exercise counter/selector writes and reads from
S-mode, denied selections, CDE gating and preservation of MINH.
`results.json` SHA-256:
`2656f4162dd7451272a4f951769473619cc9d4cad2165f49a1a2ab143bf9f665`.

**PASS:** six `--lint-only -Wall` wrapper elaborations using Verilator
5.022: `rv64gc`, `rv32gc`, `smcdeleg_rv64gc`,
`smcdeleg_rv32gc`, `pmu_deleg_rv64gc` and `pmu_deleg_rv32gc`.
The script used the same warning exclusions as `bin/lint-wally`;
the installed `uv` launcher was unavailable.

The RV64 full-core program `tests/pmu/smcdeleg.S` was assembled using
`riscv64-unknown-elf-gcc -E`, `riscv64-unknown-elf-as` and
`riscv64-unknown-elf-gcc -nostartfiles -T examples/link/link.ld`.
After `python3 bin/elf2hex` and `bash bin/extractFunctionRadix.sh`:

```sh
python3 bin/wsim pmu_deleg_rv64gc /tmp/cvw-smcdeleg-fullcore/smcdeleg.elf --sim verilator
```

**PASS:** `SUCCESS! All tests ran without failures.` The M/S/M program
checks that M-mode enables CDE/delegates counters, S-mode programs counter 3
and its event through `sireg*`, and `scountinhibit` changes only
delegated bits. ELF SHA-256:
`a47d998f3a2c64cdbff753a945288afbe7375378ceb3851d9475ff20ec049bb9`.
The successful final log is `/tmp/cvw-smcdeleg-fullcore/wsim-run-final.log`, SHA-256:
`63065207c9ea95d25c626d722b6980525b30923ddaf05f782d7dfe65e3f0e0e2`.

The host's Verilator 5.022 lacks `VL_SYSTEM_IN(std::string)`, which the
generated testbench calls. A local compatibility function was inserted only
in its generated PCH under `sim/verilator/wkdir/`, then the generated model
was rebuilt. No versioned RTL used this workaround.

## Limits

A separate `pmu_deleg_linux` image was built using OpenSBI 1.7, Linux
6.19.14, the existing static `perf` workload, and an isolated kernel probe
that directly reads and writes `siselect`, `sireg`, `sireg2` and
`scountinhibit` in S-mode. Sources and invocation are in
`linux/pmu/delegation_build.py`; generated image and manifest are in
`/tmp/wally-smcdeleg-linux/`. The kernel and Verilator model compiled.
The resumed Linux run completed at 121,759,290 cycles. The existing Linux
`perf stat` workload passed and reported cycles, instructions, branches,
branch misses, cache references and cache misses. However, the expected
`WALLY_SMCDELEG_PASS` marker did not appear, and the run harness correctly
records `FAIL` because the direct probe was not confirmed. The log also lacks
the SBI PMU driver's probe message; why the injected probe did not run remains
unresolved. Thus this is a Linux boot and ordinary PMU/perf pass, not evidence
that Linux directly accessed delegated CSRs. See `/tmp/wally-smcdeleg-linux/rtl.log`
and `rtl-result.json` for raw evidence.

The Linux driver still uses SBI for normal `perf stat`; the added kernel probe
tests direct CSR access only if it executes. No measured reduction in `perf`
programming cost exists. FPGA synthesis/timing and board behavior are also
unverified. The passing full-core test is specific to this single-core branch
and RV64 target.
