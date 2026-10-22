# Persistent engineering knowledge

Start with [AGENTS.md](../../AGENTS.md), then this index and
[current-work.md](current-work.md). Read the remaining documents only when
relevant to the task. Snapshot: 2026-10-20; this checkout is `multicore-support`. Integration
of `main:4ce065926` (including official upstream `89479dd09`) into
`f9f7a83be` passed focused and native Linux validation; see the
[current integration record](experiments/2026-10-20-multicore-upstream-integration.md).
Historical results below retain their original source scope. See the [multicore integration record](experiments/2026-10-19-multicore-main-integration.md)
for validation of the combined sources. The optional private MSI data-cache
implementation now follows [ADR 0003](decisions/0003-private-msi-data-caches.md);
see its [working-tree validation](experiments/2026-10-19-private-msi.md).
The [Linux MSI integration](experiments/2026-10-19-linux-msi.md) is a separate
completed two-hart RTL PASS at 629,148,416 cycles with both shared counters
equal to 128.
The optional stage-5 [private instruction/read-hit design](decisions/0004-private-instruction-caches.md)
and its [verification record](experiments/2026-10-19-private-l1.md) extend that baseline.
The later [independent read/write overlap](decisions/0005-independent-read-write-overlap.md)
has a [separate verification record](experiments/2026-10-19-independent-read-write.md).
The [local M-store extension](decisions/0006-local-modified-stores.md) and
[its validation](experiments/2026-10-19-local-modified-stores.md) add explicit
commit notifications and a separate Linux test for items 2 and 3.
The [multiword I/D-line design](decisions/0007-multiword-private-cache-lines.md)
and [its verification](experiments/2026-10-19-multiword-lines.md) extend the
private banks while retaining the one-word default.
The earlier
[main integration record](experiments/2026-10-18-upstream-integration.md) and
source audits retain their original revision labels.

## Find the authoritative information

| Need | Read |
| --- | --- |
| Setup, installation, supported features | [Repository README](../../README.md), [AGENTS.md](../../AGENTS.md) |
| Architecture overview and source layout | [CLAUDE.md](../../CLAUDE.md), [architecture pointers](architecture.md) |
| Verification scope | [Existing test plan](../testplans/testplan.md), [revision-specific verification notes](verification.md) |
| FPGA, Linux, ASIC flows | [Implementation notes](implementation.md), linking the existing flow documentation |
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

The optional [cache-to-cache supply](decisions/0008-cache-to-cache-supply.md)
and [its experiment](experiments/2026-10-20-cache-to-cache.md) extend MSI;
consult current-work for its independent Linux verdict.

The proposed [independent coherence homes](decisions/0009-banked-coherence-transactions.md)
and [their experiment](experiments/2026-10-20-banked-coherence.md) permit
multiple active transactions in distinct homes; validation is separate from
the completed one-home Linux cache-to-cache result.

The proposed [pipelined line transfers](decisions/0010-pipelined-cache-line-bursts.md)
and [their experiment](experiments/2026-10-20-cache-line-bursts.md) add optional
AHB bursts below MSI, with separate protocol/performance/Linux evidence.

The proposed [optional MESI state](decisions/0011-optional-mesi-exclusive-state.md)
and [its experiment](experiments/2026-10-20-mesi.md) add clean-exclusive data
permission without changing the default MSI protocol or single-core bypass.
