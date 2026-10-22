# Multicore maintenance review after recommendations 1–4

Status: **static review completed; additional recommendations proposed**.
Source: `multicore-support:e8162b462f05817d7fa78e1db9ed6e20ac86db19`.
Baseline: local `main:4ce065926c8096f34c77867c358f044ec1ea777e`, an ancestor
of HEAD. No remote refresh, branch switch, merge or RTL change was performed.
This supplements the [original review](2026-10-21-multicore-maintainability-review.md);
its numbering and historical source scope remain intact.

Implementation follow-up: recommendation 9 is recorded in the
[observation extraction](2026-10-22-multicore-test-observation.md), recommendation 10 in the
[option-interaction coverage record](2026-10-22-multicore-option-interactions.md),
and recommendation 11 in the [shared atomic-symbol record](2026-10-22-corebus-atomic-symbols.md).
Recommendation 12 remains proposed. These later implementations do not change
the source/revision scope or static-review verdict below.

Implementation follow-up: recommendation 9 is recorded in the
[observation extraction](2026-10-22-multicore-test-observation.md); recommendation 11 in the
[shared atomic-symbol execution record](2026-10-22-corebus-atomic-symbols.md).
The findings below retain their original reviewed-source scope and do not
accept the associated proposed ADR.

## Current assessment

Recommendations 1–4 are implemented. The memory topology is isolated in
`multicore_memory_system`; single-hart peripherals retain separate implementations;
ordinary regression and a dedicated workflow select multicore; the buffered
CPU/bus contract has assertions and real-adapter tests. These remove the four
original high-priority structural/verification gaps within their documented scope.
Recommendations 5 (configuration/policy ownership) and 6 (engine responsibilities)
remain applicable. Topology still belongs outside the core ISA configuration.

This audit inspected the current RTL boundaries, test runners, CI profiles,
coherence benches and Linux harness. It demonstrated no new functional failure.
It found additional coupling in verification and internal protocol representation
that should be addressed before, or alongside, further engine extraction.
Passing current profiles is not evidence that all independent option combinations
are covered.

## Additional recommendations

### 9. High: isolate test observation from cache implementation

Evidence: `tests/multicore/soc_tb.sv:42` implements architectural result lookup
by reading RAM and scanning internal cache States/Tags/Lines. It reproduces bank
selection and line/index geometry, and interprets state 2 as Modified. Separate
one-home/two-home branches name the exact generated hierarchy. The loop takes
the last matching M owner without itself rejecting multiple owners.
`tests/multicore/msifabric_tb.sv:57` identifies active work using numeric FSM
states 0/6, and lines 170–179 expose arrays and interpret state 1 as LOOKUP.
`tests/multicore/msi_tb.sv:322` synchronizes stimulus with numeric State/Transfer
encodings. Existing assertions elsewhere can catch some invariant violations;
the concern here is the observation layer's own dependency and failure behavior.

Proposed change: centralize topology-specific probes in simulation-only adapters
with semantic operations/events such as architectural-word lookup, lookup accepted,
transaction active and local store committed. Keep scenario code and scoreboards
outside these adapters. Preserve passive observation: no extra flushes or coherence
transactions just to obtain PASS. Reject ambiguous dirty owners explicitly.
Keep expected memory values and ownership invariants independently checked;
sharing an adapter must not make a DUT lookup algorithm its own reference model.

Benefit: storage/FSM changes in recommendation 6 stop forcing edits throughout
the functional tests. This is a verification boundary, separate from splitting RTL.
Acceptance: preserve full-core PASS/FAIL and traffic counts; inject duplicate
dirty ownership or a bad observation mapping and require an explicit failure;
change an internal state encoding without changing scenario code.

### 10. High: verify option independence, beyond named deployment profiles

Evidence: `tests/multicore/ci.py:16–30` always combines private I-cache, local
reads and local writes in both private-cache profiles, with equal 32-word I/D
capacities and equal four-word lines. MSI/one-home enables forwarding; MESI/two-home
enables bursts and disables forwarding. The selected matrix therefore cannot
separate the effects of MESI, homes, forwarding and bursts. It does not select
shared-cache mode, the private-cache one-hart bypass, or one-word private lines.
The separate two-home adapter fixture has private I-cache disabled, but is not
a replacement for exercising these private-cache feature interactions.
The generic runner supports additional combinations; historical experiments may
exercise them, but the current automated profiles do not retain that coverage.

Proposed change: retain the bounded per-change profiles and add an explicit
feature/interaction coverage table with a small set of complementary cases.
Include minimal MSI with optional local paths off; reads-only and writes-only
paths; MESI with one home; banked MSI without bursts; forwarding with MESI;
unequal I/D capacities and both line-size orderings; one-word lines; shared cache
with one/multiple harts; private options with one hart. Select targeted tests
per interaction and put slower combinations in a scheduled suite. Avoid a full
Cartesian product and avoid rebuilding identical common units per profile.

Benefit: independent parameters gain independent, reproducible evidence. This
extends recommendation 3's working automation rather than replacing it; it also
differs from recommendation 5's single source for configuration policy.
Acceptance: an executable coverage report maps every supported feature and
selected risky pair to a test/verdict, with unsupported/uncovered cases explicit;
check baseline and isolated toggles, semantic outputs and intended traffic effects.

### 11. Medium: give the internal atomic sideband one symbolic definition

Evidence: `src/lsu/lsu.sv:434` constructs raw 00/01/10/11 atomic codes;
`src/ebu/ahbmulticore.sv:62` separately defines LR/SC/AMO constants;
`src/ebu/ahbmsifabric.sv:126–164` compares Op against decimal 1/2/3;
`src/ebu/corebus_contract.sv:35,59` repeats binary encodings. The interface
document now specifies their meaning, but producers, consumers and monitors
still maintain that representation independently.

Proposed change: define narrowly scoped shared atomic operation symbols/type
and use them at producer, buffering, arbitration and checker boundaries. Preserve
the existing two-bit encoding and ports where tool compatibility warrants it.
Keep the core's LSUAtomicM encoding distinct from the translated bus encoding.
Do not export private cache FSM encodings as part of this public contract.

Benefit: the temporal contract gains a consistent executable vocabulary without
introducing a new topology configuration owner or restructuring an engine.
Acceptance: same single-hart lint/compatibility and multicore boundary results,
including all named negative cases; no port-width, latency or synthesis-state
change. A broad conversion of existing AHB ports to SV interfaces is unnecessary.

### 12. Medium: share downstream test infrastructure across topologies

Evidence: the downstream AHB wait/burst monitor in
`tests/multicore/msi_tb.sv:136–172` is byte-identical to
`tests/multicore/msifabric_tb.sv:98–134` (37 lines). Both benches also implement
closely matching pipelined memory/error slaves and core transaction tasks.
The reusable corebus_contract checks the upstream buffered hart port; it does
not remove this separate downstream duplication.

Proposed change: extract a test-only pipelined AHB memory/fault model and passive
downstream protocol checker; then reuse common master tasks where their contracts
match. Leave topology-specific concurrency, home routing, reservation and MESI
scenarios in their benches. Keep the checker independent of the DUT burst engine
and keep the real EBU/ahbinterface fixture as a distinct integration test.

Benefit: an ERROR/wait/SEQ fix reaches both topology tests consistently, and new
topologies can reuse verified stimulus infrastructure without copying the suite.
Acceptance: matched pre/post results for RV32/RV64, waits, every fault beat and
reset, preserving exact transfer/writeback counts and overlap checks; malformed
SEQ and data-phase mutations must still fail. Add a per-test watchdog while
touching the common driver: several access tasks currently wait without a local
bound, although the CI job and ordinary regression have outer time limits.

## Suggested merge scope and order

Prioritize 9 and a bounded first slice of 10 before decomposing engines. Complete
5 with effective-configuration consistency checks, then apply 11 and the small
test-infrastructure extraction in 12. Implement 6 incrementally against those
stable boundaries; a wholesale coherence rewrite would increase merge risk.
Each change should be independently reviewable and retain the single-hart bypass.
These are proposed priorities, not newly accepted architectural decisions.

The original findings 7 (capability limits) and 8 (documentation/decision status)
remain separate merge considerations. In particular, this review does not add
precise CPU bus exceptions, DMA coherence or FPGA timing/boot evidence, and does
not accept proposed ADRs. Remote workflow execution and the complete ACT regression
remain unexecuted in the recommendation-4 record.

## Evidence and limitations

At review start the working tree was clean. Static comparisons used `git diff
main`, source searches and numbered source inspection at the revisions above.
The delta is 97 files, 10,961 additions and 204 deletions, including documentation
and tests; this is not a measure of RTL complexity alone.

Existing evidence was checked rather than re-running unchanged simulations:
`sim/verilator/wkdir/corebus-contract/final-ci/results-all.json` reports all four
profiles PASS. All 378 recorded source hashes match this checkout, including
the recommendation-4 source files. Its source_commit field names parent
`8ecb9ef1b`; the hashes identify the then-uncommitted implementation now committed
as `e8162b462`. Aggregate manifest SHA-256:
`b3510ee9c3922ef5d1ef61d7433f64f2d6b1799cfa88d30aebbc2df43699455f`.
See the [boundary experiment](2026-10-21-core-bus-contract.md) for tools, commands,
execution counts, archived evidence and unverified scope.

No new RTL build, simulation, Linux boot, formal run or hardware check was
performed for this static review. Recommendations above describe observed
maintenance dependencies and coverage gaps, not reproduced functional regressions.
