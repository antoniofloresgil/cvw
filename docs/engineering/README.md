# Persistent engineering knowledge

Start with [AGENTS.md](../../AGENTS.md), then this index and
[current-work.md](current-work.md). Read the remaining documents only when
relevant to the task. Snapshot: 2026-10-19, `opensource-fpga-bitstream`
integrates `main:82d0b80f7` (official upstream `712ee9719`) over open-flow
`23ba9c2a7`. See the [branch integration record](experiments/2026-10-19-open-fpga-main-integration.md)
for executed checks and the [DDR3 record](experiments/open-ddr3-bringup.md)
for unresolved hardware bring-up. Earlier records retain their revision labels.

## Find the authoritative information

| Need | Read |
| --- | --- |
| Setup, installation, supported features | [Repository README](../../README.md), [AGENTS.md](../../AGENTS.md) |
| Architecture overview and source layout | [CLAUDE.md](../../CLAUDE.md), [architecture pointers](architecture.md) |
| Verification scope | [Existing test plan](../testplans/testplan.md), [revision-specific verification notes](verification.md) |
| FPGA, Linux, ASIC flows | [Implementation notes](implementation.md), linking the existing flow documentation |
| Significant decisions | [ADR 0001: knowledge organization](decisions/0001-knowledge-organization.md), [ADR 0002: multicore cache](decisions/0002-shared-multicore-cache.md) |
| Results | [Upstream integration](experiments/2026-10-18-upstream-integration.md), [Linux SMP](experiments/2026-10-18-linux-smp.md), [open DDR3 bring-up](experiments/open-ddr3-bringup.md) |
| Active work, branch boundaries, unresolved questions | [Current work](current-work.md) |
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
