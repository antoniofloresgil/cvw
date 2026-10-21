# PMU module-boundary refactor

Question: can Wally's PMU event, filter, overflow and delegation logic be
separated from the common counter CSR file without changing observable CSR
behavior?

Source: `adding-mpu-support` worktree above `e6a459188`, 2026-10-21, including
the uncommitted event-mode correction. SHA-256 of the relevant sources:

| File | SHA-256 |
| --- | --- |
| `src/privileged/csrc.sv` | `c7bc7e7c21e16c73de693454b7341a72bbf1727aab00c6e53ee48cab05f562fd` |
| `src/privileged/pmuevents.sv` | `1c2723244fd352168ae554d05cf0fe0bfcc05ae8539f37f557ea647e6b36752d` |
| `src/privileged/pmucountercontrol.sv` | `329b075dfe3447c3eea87c7559a9c76f3aa188e0e3f8a563a16459ab6b102cb8` |
| `tests/pmu/run.py` | `31ac0b82cd89eb2eac93f6ddca0323d3ed98165bd2b97dcf9dd58cc4b8d71e86` |

After `source ./setup.sh`, run
`python3 tests/pmu/run.py --work /tmp/cvw-pmu-modular`. Verilator 5.022
reported PASS for all 22 directed RV32/RV64 CSR and interrupt cases,
including COUNTERS=3/8/32, Sscofpmf, Smcntrpmf and Smcdeleg combinations.
The generated event map and all board DTBs also passed. The result manifest
is `/tmp/cvw-pmu-modular/results.json`, SHA-256
`fdc7129f90b86d6dba7b9a375400f08c51e0fb8dca45e481b8b7d4da3fc1b9e7`.

Full-core `wallywrapper` lint passed for the six base configurations
`rv32e`, `rv32i`, `rv32imc`, `rv32gc`, `rv64i`, `rv64gc`, and the four
PMU derivatives `sscofpmf_rv64gc`, `sscofpmf_rv32gc`,
`pmu_deleg_rv64gc`, `pmu_deleg_rv32gc`. The command was
`verilator --lint-only --top-module wallywrapper` with `src/cvw.sv`,
`testbench/wallywrapper.sv`, all `src/**/*.sv`,
the target's `config/shared`, base and derivative include paths, plus the
warning suppressions from `bin/lint-wally`. The installed Verilator rejects
the script's `--quiet` option, so it was omitted. `git diff --check` passed.

The directed tests establish the tested CSR/event behavior. No gate-level or
cycle-by-cycle comparison to the pre-refactor RTL was run. A full-core HPM
simulation remains pending because the installed Verilator 5.022 generates an
undefined `VL_SYSTEM_IN` call for the testbench's dynamic-string `$system`;
see the [mode-attribution record](2026-10-21-pmu-event-modes.md). Linux,
FPGA synthesis and physical hardware were not rerun for this refactor.
