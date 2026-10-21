# PMU event privilege attribution at mode boundaries

Question: do Sscofpmf filters use the mode that initiated an early-stage or
multicycle event when the global privilege mode changes before the event is
counted?

Source: `adding-mpu-support` worktree above `e6a459188` on 2026-10-21.
The RTL/test diff (`git diff --binary -- src/privileged/csrc.sv
tests/pmu/csrc_tb.sv | sha256sum`) was
`313a61c3adcc3298f078e6d623567da0972e3e978cb8d2028f1201b9d59d3550`.
The `sscofpmf_rv32gc` and `sscofpmf_rv64gc` derivatives and the base
`rv64gc` configuration were checked. Verilator was 5.022 from `/opt/riscv`.

After `source ./setup.sh`, run
`python3 tests/pmu/run.py --work /tmp/cvw-pmu-mode-tags`. All 22 directed
CSR/interrupt cases and the board DTB checks passed. The new RV32/RV64 cases
start cache stalls and division in U mode, change the global mode to M, then
check delayed misses and remaining busy cycles against U-only filters. They
also check that M-origin events remain excluded after a transition to U, and
move load/store stalls from D to M across a mode change. The results
manifest is `/tmp/cvw-pmu-mode-tags/results.json`, SHA-256
`167557e996e466034a2e72244bcb091ba7b7b4ebc395a4cc0d53a57d386996dd`.
The RV32 and RV64 32-counter Sscofpmf run logs have SHA-256
`976efe0c821fdd4b4e3effe90aa8e22e0c479dd4d183d358e0502afb18de1666`
and `f1c6fb5d8590a0b4c1e90a5188fc8c33842fe6924efb42d3eed4be58e005ff88`.

Full-core `wallywrapper` lint passed for `rv64gc`, `sscofpmf_rv64gc` and
`sscofpmf_rv32gc` using the options in `bin/lint-wally`, omitting `--quiet`
because the installed Verilator rejects that option. `git diff --check`
passed. The repository's `uv`-based pre-commit hooks could not run because
`uv` is not installed in this environment.

A full-core `hpmcounters.elf` simulation was attempted with
`python3 bin/wsim rv64gc /tmp/cvw-pmu-mode-tags/hpmcounters.elf --sim verilator`.
The ELF was assembled directly with `-march=rv64gc_zicbom` because the
installed assembler rejects the broader Makefile ISA string. Verilator
generated C++ that failed to compile: `VL_SYSTEM_IN` was not declared in
`Vtestbench___024root__DepSet_hfc24d085__2.cpp`. A minimal external module
with `$system` on a dynamic string reproduces the same failure; Verilator
5.022's matching headers do not define `VL_SYSTEM_IN`. The pending check is to
use a different Verilator version, confirm the testbench compiles, and rerun
`hpmcounters.elf` before claiming a full-core verdict. Linux, FPGA synthesis
and physical hardware were not run.
The directed test changes the mode input explicitly; it does not model an
entire trap/return pipeline or establish security-grade precise accounting.
