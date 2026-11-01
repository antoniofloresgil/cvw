# ADR 0021: passive semantic adapters for multicore test observation

Status: **proposed**; implemented on `multicore-support` parent `4986fa5f8`,
following the user's request for recommendation 9 on 2026-10-22. Implementation
and test results do not automatically accept this decision.

## Context and choice

The [post-refactor review](../experiments/2026-10-21-multicore-post-refactor-review.md)
found that architectural signature lookup and coherence scenarios depended on
raw arrays, numeric permission/FSM/transfer encodings and generated home paths.
The full-core lookup could choose the last of several dirty owners. The storage
extraction did not remove these verification dependencies.

Use test-only type-bound cache/bridge observers, with semantic permission and
event names, plus centralized SoC/fabric topology adapters. One passive word
lookup handles both one-home and banked private snapshots, rejecting ambiguous
dirty owners. Keep the expected reference data and scenario sequencing outside
the adapters. Retain explicit wire-code stimulus for the separate atomic protocol.
See the [observation contract](../interfaces/multicore-observation.md).

Adding synthesizable debug ports would change production interfaces solely for
tests. Flushing to RAM before checking signatures would perturb traffic, timing
and ownership. Merely moving numeric decodes into several helpers would retain
independent encoding owners. Bindings instead use existing DUT enum symbols,
map them to a distinct test vocabulary and expose no private FSM codes to scenarios.

## Consequences and verification

Only simulation builds explicitly include the observers. No production RTL,
package, port, state machine, ordering or cache-storage implementation changes.
Verilator source lists put the observation package before consuming benches.
Generated hierarchy knowledge remains in the topology adapters; future hierarchy
changes need adapter updates rather than scattered scenario edits.

Retain existing conflict/exclusion assertions and exact sampling edges/counters.
Expected region geometry is computed independently in the bridge observer.
Negative snapshot tests reject duplicate owners and incorrect data mapping;
unchanged real scenarios run against reordered permission, FSM and transfer
encodings. The bounded CI bus case retains this coverage. Compare all four
profiles' PASS/cycle/traffic signatures against parent-source evidence.
See the [execution record](../experiments/2026-10-22-multicore-test-observation.md).
No formal, four-state, hardware or new Linux qualification is implied.
