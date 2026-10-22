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
Recommendation 2 was implemented on parent `67ec3d991`:
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
the test runner; it is not a PASS. Recommendations 2 and 3 were committed and
pushed together as `8ecb9ef1b` on `multicore-support`.
Recommendation 3 was committed in that revision: shared
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
Recommendation 4 was committed and pushed as `e8162b462`:
the [buffered core/bus contract](interfaces/core-bus.md) specifies address
acceptance, delayed/live write payloads, atomic sideband, AMO exclusion/pairing,
retained SC results and ERROR/flush/reset semantics. A reusable port checker
and engine assertions add simulation checks without changing the datapath or
single-hart bypass. Real ahbinterface/busfsm/EBU fixtures are selected by CI:
RV32/RV64, two/three harts, one/two homes, latency 0/3, and six named negative
cases. Final validation passed: all four CI cases, 16 real-adapter executions,
six named negative fixtures, seven standard and seven topology lints, 28
full-core atomic/smoke programs, the existing coherence/burst/peripheral matrix
and scoped pre-commit. MEM3 retention is explicitly checked via BusCommitted/
BusStall while pipeline stall remains asserted across an IFU reply. Source
hashes of the final aggregate and both boundary manifests match the final tree.
No new Linux, remote CI, full ACT regression or hardware verification was run.
See proposed
[ADR 0016](decisions/0016-core-bus-temporal-contract.md) and the
[boundary record](experiments/2026-10-21-core-bus-contract.md).
Other review recommendations and proposed ADR statuses remain unchanged.

Follow-up static review at `e8162b462` confirms recommendations 1–4 are present.
At that reviewed source, 5 (configuration/policy ownership) and 6 (engine
decomposition) remained pending.
The [post-refactor review](experiments/2026-10-21-multicore-post-refactor-review.md)
proposes additional recommendations 9–12: simulation observation adapters,
feature-interaction coverage, shared atomic symbols and reusable downstream test
infrastructure. Prioritize the observation boundary and complementary coverage
before further RTL extraction. All 378 sources in the final CI manifest match
the reviewed checkout; no new simulations or functional refactors were performed.
These recommendations remain proposals; no merge into main was performed.

Recommendation 5 is implemented on parent `e8162b462`: shared schema/profiles,
generated SV parameters and validation, one physical RAM predicate, and effective
RTL/DT/image-manifest checks. Public SoC parameters and 8 KiB private defaults are
preserved; topology remains outside cvw_t. All four final CI cases, the 300-vector
policy/DT negative suite, seven standard lints, eight additional shared-cache
full-core runs and Linux harness build/reuse passed. No new Linux boot or hardware
result is claimed. See proposed [ADR 0017](decisions/0017-multicore-configuration-policy.md)
and the [configuration record](experiments/2026-10-21-multicore-configuration-policy.md).
Recommendation 6 was still pending at that source; additional recommendations
9–12 remain proposals. No merge into main was performed.

Recommendation 6 is implemented on parent `349263f55`: LR/SC reservations and
sticky SC results, instruction banks and data-word arrays have separate modules.
Bridge arbitration/AMO locks and MSI/MESI metadata/control preserve their cycle
behavior in the compared tests.
The [storage contract](interfaces/multicore-storage.md) specifies ports, edge
priorities and current combinational-read/line-wide bandwidth before any BRAM work.
All four final CI cases, seven standard lints, isolated RV32/RV64 engine fixtures,
eight one-word coherence cases and eight shared-cache full-core runs passed.
All 75 frozen baseline PASS/cycle/traffic signatures match. See proposed
[ADR 0018](decisions/0018-multicore-engine-boundaries.md) and the
[extraction record](experiments/2026-10-22-multicore-engine-extraction.md).
No new Linux, FPGA, formal or main integration result was obtained.

FPGA synthesis/timing and dual-core Nexys Video boot remain unverified. PMU
support remains on `adding-mpu-support`; other branches are unchanged.
