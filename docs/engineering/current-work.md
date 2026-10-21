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

Optional Sscofpmf hardware is committed as `f1a5b7744` with RV32/RV64
derived configs. The directed 14-case PMU run, nine RTL lints and a full-core
`hpmcounters.elf` simulation passed; see
[ADR 0014](decisions/0014-sscofpmf-counter-overflow.md) and the
[verification record](experiments/2026-10-21-sscofpmf.md).

Smcntrpmf fixed-counter filtering is committed as `776ae473b`.
Eighteen directed cases, 13 RTL lint elaborations and the
full-core M/U/M transition and HPM regression checks pass. See
[ADR 0015](decisions/0015-smcntrpmf-fixed-counter-filter.md) and its
[verification record](experiments/2026-10-21-smcntrpmf.md). Linux `perf` with
privilege-filtered counters, FPGA synthesis/timing and physical-board behavior
remain unverified. Multicore RTL and coherence remain on `multicore-support`
and are not part of this branch.

Smcdeleg/Ssccfg counter delegation is implemented in the working tree above
`776ae473b`, with one configuration switch for the required pair. The
directed RV32/RV64 CSR suite, six RTL lint elaborations and the RV64
full-core M/S/M test have passed. A separate `pmu_deleg_linux` Linux image
and kernel S-mode direct-CSR probe were prepared. Linux completed at
121,759,290 cycles and the existing `perf stat` integration passed, but the
direct probe marker was absent, so Linux direct access remains unverified.
The run record documents this distinction. FPGA timing and board operation
also remain unverified. See [ADR 0016](decisions/0016-smcdeleg-ssccfg-counter-delegation.md)
and the [experiment](experiments/2026-10-21-smcdeleg-ssccfg.md).
