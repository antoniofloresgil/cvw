# Persistent engineering knowledge

Start with [AGENTS.md](../../AGENTS.md), then this index and
[current-work.md](current-work.md). Read the remaining documents only when
relevant to the task. Snapshot: 2026-10-23, `opensource-fpga-bitstream`
integrates `main:1d5677648` (official upstream `89479dd09`) over open-flow
`f950a7753`. The open LiteDRAM flow and optional multicore implementation now
coexist; the FPGA wrapper retains the default single-hart topology.
See the [branch integration record](experiments/2026-10-23-open-fpga-main-integration.md)
for validation and the [DDR3 record](experiments/open-ddr3-bringup.md) for
the open-flow hardware bring-up, which has since reached DDR3 and Linux on the
board (see [current work](current-work.md)). Earlier records retain their original
revision and branch scopes, including the successful Vivado Linux boot.

## Find the authoritative information

| Need | Read |
| --- | --- |
| Setup, installation, supported features | [Repository README](../../README.md), [AGENTS.md](../../AGENTS.md) |
| Architecture overview and source layout | [CLAUDE.md](../../CLAUDE.md), [architecture pointers](architecture.md) |
| Verification scope | [Existing test plan](../testplans/testplan.md), [revision-specific verification notes](verification.md) |
| FPGA, Linux, ASIC flows | [Implementation notes](implementation.md), linking the existing flow documentation |
| PMU kernel and OpenSBI versions | [PMU software compatibility](pmu-software-compatibility.md) |
| Significant decisions | [ADR 0001: knowledge organization](decisions/0001-knowledge-organization.md), [ADR 0002: multicore cache](decisions/0002-shared-multicore-cache.md), [ADR 0003: private MSI](decisions/0003-private-msi-data-caches.md) |
| Results | [Multicore/main integration](experiments/2026-10-19-multicore-main-integration.md), [upstream integration](experiments/2026-10-18-upstream-integration.md), [Linux SMP](experiments/2026-10-18-linux-smp.md), [open DDR3 bring-up](experiments/open-ddr3-bringup.md) |
| Active work, branch boundaries, unresolved questions | [Current work](current-work.md) |
| Extracted multicore memory boundary | [ADR 0013](decisions/0013-multicore-memory-subsystem-boundary.md), [extraction verification](experiments/2026-10-21-memory-subsystem-extraction.md) |
| Multicore isolation and maintenance risks before merging | [2026-10-21 architecture review](experiments/2026-10-21-multicore-maintainability-review.md) |
| Remaining maintenance work after recommendations 1–4 | [Post-refactor review and additional recommendations 9–12](experiments/2026-10-21-multicore-post-refactor-review.md) |
| Multicore profile/default ownership and RTL/DT consistency | [Profile definition](../../config/multicore/README.md), [proposed ADR 0017](decisions/0017-multicore-configuration-policy.md), [execution record](experiments/2026-10-21-multicore-configuration-policy.md) |
| Single-hart compatibility and peripheral isolation | [Proposed ADR 0014](decisions/0014-single-hart-peripheral-isolation.md), [compatibility checks](experiments/2026-10-21-singlecore-compatibility.md) |
| Automated single-core/multicore CI and regression | [Proposed ADR 0015](decisions/0015-automated-multicore-verification.md), [procedure](verification.md#automated-multicore-matrix), [execution record](experiments/2026-10-21-multicore-ci.md) |
| Buffered CPU/bus timing, atomic sideband and abort contract | [Interface](interfaces/core-bus.md), [proposed ADR 0016](decisions/0016-core-bus-temporal-contract.md), [boundary checks](experiments/2026-10-21-core-bus-contract.md) |
| Reservation and I/D storage boundaries and RAM timing | [Storage/event interface](interfaces/multicore-storage.md), [proposed ADR 0018](decisions/0018-multicore-engine-boundaries.md), [extraction record](experiments/2026-10-22-multicore-engine-extraction.md) |
| Experimental multicore capability limits, DMA and error integration | [Capability contract](interfaces/multicore-capabilities.md), [proposed ADR 0019](decisions/0019-multicore-capability-scope.md), [execution record](experiments/2026-10-22-multicore-capability-scope.md) |
| Private-cache capacity decision and documentation/publication status | [Accepted ADR 0012](decisions/0012-private-cache-default-capacity.md), [capacity experiment](experiments/2026-10-20-private-cache-capacity.md), [reconciliation](experiments/2026-10-22-multicore-documentation-reconciliation.md) |
| Shared translated atomic-operation symbols | [Proposed ADR 0020](decisions/0020-corebus-atomic-symbols.md), [interface](interfaces/core-bus.md), [execution record](experiments/2026-10-22-corebus-atomic-symbols.md) |
| Passive multicore test observation | [Proposed ADR 0021](decisions/0021-multicore-test-observation.md), [observation contract](interfaces/multicore-observation.md), [execution record](experiments/2026-10-22-multicore-test-observation.md) |
| Independent multicore option combinations | [Additional recommendation 10](experiments/2026-10-21-multicore-post-refactor-review.md#10-high-verify-option-independence-beyond-named-deployment-profiles), [coverage execution record](experiments/2026-10-22-multicore-option-interactions.md) |
| Shared downstream AHB test fixture | [Additional recommendation 12](experiments/2026-10-21-multicore-post-refactor-review.md#12-medium-share-downstream-test-infrastructure-across-topologies), [extraction record](experiments/2026-10-22-multicore-downstream-fixture.md) |
| Contribution process | [CONTRIBUTING.md](../../CONTRIBUTING.md) |

Existing flow documentation and executable sources remain authoritative for
their respective subjects. These notes add provenance, cross-references and
missing constraints; they do not replace those documents. Where documentation
disagrees, check the implementation and scripts at the stated revision and
record the discrepancy rather than silently combining different versions.

## Maintenance contract

- Scope each claim to a Git revision, branch and configuration. A feature on
  another branch is not a feature of the current checkout.
- Update only affected documents after substantial work: interfaces and
  invariants in architecture notes; meaningful choices in an ADR; new test
  procedures in verification notes; implementation experiments in a result
  record; changing objectives and blockers in `current-work.md`.
- ADRs need context, alternatives, selected approach and rationale, affected
  modules/configurations, compatibility/performance effects, verification and
  status. Use **proposed**, **accepted**, **superseded** (link the replacement)
  or **rejected**. Acceptance is scoped explicitly; an experiment or suggestion
  alone does not establish an accepted decision. Preserve earlier decisions
  when superseding them instead of erasing their history.
- Experiment records need a question, exact source/configuration, tools and
  constraints, reproducible commands or script references, observed results,
  evidence locations and limitations. Use the result states defined in
  [verification.md](verification.md). Keep raw output outside permanent docs.
- Keep `current-work.md` a checkpoint, not a transcript. Move durable results
  into a decision/result record and link them. Record unknowns and hypotheses
  explicitly; do not reconstruct unavailable conversations.
- Do not load or update every document for every task. Check links and source
  references after documentation changes. Documentation work alone does not
  establish a new RTL, simulation or hardware verification result.

Historical branch references below use immutable commits. For local inspection,
use `git show <commit>:<path>`; no branch switch or merge is required. If this
index is brought into another branch, refresh its checkout-specific notes and
`current-work.md` before treating them as current state.

The proposed [SBI PMU counting integration](decisions/0013-sbi-pmu-perf-stat.md)
and [its experiment](experiments/2026-10-20-sbi-pmu.md) belong to
`adding-mpu-support`, with main integrated through `4ce065926` and again on
2026-11-01 (main `568a9ed65`, which brings the multicore RTL; the PMU has not
been checked in multicore configurations). The post-merge checks are tracked in the
[PMU/main integration record](experiments/2026-10-21-pmu-main-integration.md).
Optional counter overflow and filtering on this branch are tracked in
[ADR 0014](decisions/0014-sscofpmf-counter-overflow.md) and the
[Sscofpmf verification record](experiments/2026-10-21-sscofpmf.md).
Fixed-counter mode filtering is tracked in
[ADR 0015](decisions/0015-smcntrpmf-fixed-counter-filter.md) and the
[Smcntrpmf verification record](experiments/2026-10-21-smcntrpmf.md), with a
separate [Linux perf integration result](experiments/2026-10-21-smcntrpmf-linux.md).
Counter delegation is tracked in
[ADR 0016](decisions/0016-smcdeleg-ssccfg-counter-delegation.md) and the
[Smcdeleg/Ssccfg experiment](experiments/2026-10-21-smcdeleg-ssccfg.md).
The proposed PMU module boundary is tracked in
[ADR 0017](decisions/0017-pmu-module-boundary.md) and its
[refactor experiment](experiments/2026-10-21-pmu-modules.md).

The optional [cache-to-cache supply](decisions/0008-cache-to-cache-supply.md)
and [its experiment](experiments/2026-10-20-cache-to-cache.md) extend MSI;
consult current-work for its independent Linux verdict.

The proposed [independent coherence homes](decisions/0009-banked-coherence-transactions.md)
and [their experiment](experiments/2026-10-20-banked-coherence.md) permit
multiple active transactions in distinct homes; validation is separate from
the completed one-home Linux cache-to-cache result.

The accepted optional [pipelined line transfers](decisions/0010-pipelined-cache-line-bursts.md)
and [their experiment](experiments/2026-10-20-cache-line-bursts.md) add optional
AHB bursts below MSI, with separate protocol/performance/Linux evidence.

The proposed [optional MESI state](decisions/0011-optional-mesi-exclusive-state.md)
and [its experiment](experiments/2026-10-20-mesi.md) add clean-exclusive data
permission without changing the default MSI protocol or single-core bypass.
