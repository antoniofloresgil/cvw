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
Recommendation 2 is now implemented in the working tree on `67ec3d991`:
single-hart CLINT/PLIC use upstream-shaped modules with explicitly scoped
generic corrections, multi-hart implementations live in separate modules,
no-bus clock/reset outputs match upstream, and cached LSU atomic metadata
follows walker ownership. See proposed [ADR 0014](decisions/0014-single-hart-peripheral-isolation.md)
and the [compatibility record](experiments/2026-10-21-singlecore-compatibility.md).
Seven lints, four peripheral comparisons (12,000 common transactions), two
clock/reset cases, translated AMO/PTE updates with a negative mutation, bus/
peripheral units and 12 full-core atomic/smoke executions passed. No new Linux
or private-cache regression was run. The unsupported cacheless/virtual-memory
trial was rejected by the existing configuration assertion, then removed from
the test runner; it is not a PASS. Recommendations 2 and 3 are recorded together in the commit containing this checkpoint.
Recommendation 3 is implemented in the same working tree: shared
`tests/multicore/ci.py` cases for single-default, bus, MSI/one-home and
MESI/two-home configurations are selected by ordinary regression and the new
Multicore workflow. `regression-wally --multicore` runs only this matrix.
It includes explicit multi-hart lint, controller wait/error/ordering checks
and full-core programs; Linux remains separate. All four final cases passed:
seven topology lints, four single-hart peripheral comparisons, two clock/reset
checks, two translated AMO programs, 16 coherence and four burst unit runs,
common bus/peripheral/atomic units, and 28 full-core atomic/smoke programs.
Workflow actionlint, scoped pre-commit, ordinary regression selection and
failure/stale-result propagation checks passed. Remote GitHub execution and
the complete ACT regression were not run. See proposed [ADR 0015](decisions/0015-automated-multicore-verification.md)
and the [matrix record](experiments/2026-10-21-multicore-ci.md).
Other review recommendations and proposed ADR statuses remain unchanged.

FPGA synthesis/timing and dual-core Nexys Video boot remain unverified. PMU
support remains on `adding-mpu-support`; other branches are unchanged.
