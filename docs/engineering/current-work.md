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

FPGA synthesis/timing and physical-board `perf` remain unverified for the PMU.
Sscofpmf, sampling and privilege filtering are later work. Multicore RTL and
coherence remain on `multicore-support` and are not part of this branch.
