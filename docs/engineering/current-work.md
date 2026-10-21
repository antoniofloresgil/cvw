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

The reviewed merge is committed and, on 2026-10-21, local HEAD `0533e764d`
matches the fetched `origin/multicore-support` reference.
FPGA synthesis/timing and dual-core Nexys Video boot remain unverified. PMU
support remains on `adding-mpu-support`; other branches are unchanged.

Current objective (2026-10-21): assess maintenance and configuration isolation
before integrating multicore into main. The
[architecture review](experiments/2026-10-21-multicore-maintainability-review.md)
records proposed improvements and newly executed seven-configuration lint plus
four structural elaboration checks. Single-core coherence bypass passed those
structural checks; single-core functional equivalence is not established by them.
No refactoring or merge into main was performed. Recommendations and proposed
ADR statuses still require an explicit engineering decision.
