# ADR 0019: explicit experimental multicore capabilities and qualification scope

Status: **proposed**; implemented on `multicore-support` parent `1a40aaac2`.
Implementation/tests do not accept the future DMA or architectural-error designs.

## Context and proposed choice

Recommendation 7 lists existing capability limits, not newly reproduced RTL
regressions: only hart-path writers participate in coherence/atomic ordering,
HRESP recovery is transport behavior, and multicore FPGA/arbitrary-hart claims
lack qualification. Avoid making a successful profile build or transport test
look like broader system qualification.

Extend the existing profile schema with a canonical capability contract and
path-specific writer/error/writeback semantics. Reports distinguish implementation
availability, configuration constraints and revision-specific execution evidence.
Attach reports to effective configurations/Linux manifests and explicit execution
scope to CI verdicts. Add optional --require-capability checks that fail before
building when a requested property is unavailable. Validate canonical metadata
rather than trusting caller-edited claims. The native bypass remains separately
scoped from the buffered hart contract.

Use a simulation-only full-core fault-free guard in the experimental SoC/Linux
harnesses. Keep intentional fault injection in transport/controller fixtures.
Document the [integration contract](../interfaces/multicore-capabilities.md),
including the separate future design/acceptance criteria for coherent/noncoherent
DMA, precise CPU error delivery, dirty-writeback failures, FPGA and scaling.

## Alternatives and consequences

Implementing a DMA ingress or precise traps as a small change would omit protocol,
retirement, partial-effect and platform error-policy decisions. A blanket three-hart
RTL cap would confuse measured coverage with legal parameter ranges and prevent
valid experiments. Documentation alone would leave manifests and automated build
requirements capable of overstating the available properties.

Keep legal topology limits unchanged, name them as addressability/recipe limits,
and record actual execution counts separately. Requirements do not enable hardware;
unsupported/unverified properties remain rejected. No new core port, coherence FSM,
DMA snoop path, architectural trap, retry policy or FPGA qualification is introduced.
Schema/report changes require regenerating existing Linux image manifests through
the maintained builder; they are not silently upgraded into new evidence.

## Verification

Exercise each path and requirement, forged capability claims, and no-build rejection
of unsupported DMA requirements. Require the full-core guard's global/hart failures
to trigger its exact diagnostic while reset and fault-free execution pass. Retain
existing transport error/dirty-writeback tests and execute the ordinary CI matrix.
See the [execution record](../experiments/2026-10-22-multicore-capability-scope.md)
for actual results and unexecuted qualification work.
