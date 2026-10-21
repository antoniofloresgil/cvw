# Current work

Branch: `adding-mpu-support`. Main `4ce065926` (official upstream through
`89479dd09`) is integrated into PMU feature parent `8cb89bab9`. Synthesizable
Zicntr/Zihpm counters, the OpenSBI event map and Linux `perf stat` support are
preserved. `csrc.sv` kept the PMU parent's non-comment RTL tokens.

Combined-source checks PASS: six PMU CSR/event configurations, eight board
DTS, ten RTL lints and the full-core HPM test. A fresh single-core Linux PMU
run also passed at 121,617,639 cycles with seven counter checks and actual
`perf stat`. See the
[PMU/main integration record](experiments/2026-10-21-pmu-main-integration.md)
for parent revisions, model and image hashes, commands and evidence limits.

Optional Sscofpmf hardware is now implemented in the working tree above
`92c007ae5` with RV32/RV64 derived configs. The directed 14-case PMU run and
nine RTL lints and a full-core `hpmcounters.elf` simulation pass; see
[ADR 0014](decisions/0014-sscofpmf-counter-overflow.md) and the
[verification record](experiments/2026-10-21-sscofpmf.md). Linux sampling,
FPGA synthesis/timing and
physical-board `perf` remain unverified. Multicore RTL and coherence remain
on `multicore-support` and are not part of this branch.
