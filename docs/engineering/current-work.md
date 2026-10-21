# Current work

Branch: `multicore-support`. Integrated main `4ce065926` (official upstream
`89479dd09`) into feature parent `f9f7a83be`. Configurable hart/interrupt/
atomic interfaces and optional MSI/MESI private caches are preserved; private
I/D defaults remain 8 KiB and single-core coherence bypass remains.

Combined-source validation passed: controller/peripheral checks, 41 full-core
runs, RV32/RV64 directed tests, configuration/FPGA lint and scoped pre-commit.
Fresh native Linux SMP passed after 347,795,562 cycles with both CPUs online
and atomic/protected counters 128/128. See the
[integration record](experiments/2026-10-20-multicore-upstream-integration.md)
for exact revisions, model/log hashes and evidence scope.

Completed objective (2026-10-21): implement recommendation 1 from the
[maintenance review](experiments/2026-10-21-multicore-maintainability-review.md)
on parent `ce02cf1ad`, following accepted
[ADR 0013](decisions/0013-multicore-memory-subsystem-boundary.md).
Memory topology and capability assertions now live in `multicore_memory_system`;
SoC parameters, hart/uncore hierarchy and clock/reset ownership are preserved.
No CPU/peripheral/cache-engine behavior or base configuration was changed.

Focused validation passed: seven standard lints, four structural checks,
two RV32 integration lints, 40 matched before/after program comparisons
(80 executions), and seven native RV64/RV32 directed programs. Fresh two-hart
RTL Linux SMP passed after 339,802,249 cycles with both CPUs online and
atomic/protected counters 128/128; see the
[extraction record](experiments/2026-10-21-memory-subsystem-extraction.md).
No merge into main was performed.
Other review recommendations and proposed ADR statuses remain unchanged.

FPGA synthesis/timing and dual-core Nexys Video boot remain unverified. PMU
support remains on `adding-mpu-support`; other branches are unchanged.
