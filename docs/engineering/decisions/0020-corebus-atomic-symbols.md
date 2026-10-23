# ADR 0020: shared symbols for the translated core/bus atomic sideband

Status: **proposed**; implemented on `multicore-support` parent `7c2a28642`
following the user's request to implement recommendation 11 on 2026-10-22.
Implementation/testing and acceptance of ADR 0010/0012 do not accept this ADR.

## Context and choice

The [post-refactor review](../experiments/2026-10-21-multicore-post-refactor-review.md)
found independent definitions of the translated two-bit atomic operation in
LSU, arbiters and the temporal checker. The reservation extraction later added
another local definition. The interface meaning is common; its representation
should have one executable owner.

Define COREBUS_NORMAL/LR/SC/AMO as explicitly sized logic [1:0] constants in
package cvw, retaining wire values 00/01/10/11. All affected production modules
already import cvw, so no new compilation unit, package dependency, configuration
field or source-list change is needed. Use these names at LSU translation,
EBU selection, bridge/fabric decisions, reservation events and contract checks.

An enum with typed ports would impose casts and touch unrelated connections.
A new package would require source-order changes throughout build flows.
Macros lack the existing package namespace. Shared constants provide the needed
vocabulary with the smallest interface change. Aggregate zero resets remain
zero initialization, not a separate encoding definition.

## Consequences and verification

Keep LSUAtomicM's internal bit-mask meaning distinct from the translated bus
encoding. Do not change AHB transfer codes, cache/FSM state symbols, data paths,
port widths, pipeline timing or synthesis registers. Synthetic boundary/atomic
fixtures retain literal wire-code stimulus to check the public encoding
independently of the shared implementation constants.

Use standard lint and the existing single-core/multicore matrix, including all
six named negative endpoint cases. Compare baseline PASS/cycle/traffic signatures.
See the [execution record](../experiments/2026-10-22-corebus-atomic-symbols.md)
for measured verdicts and limitations. No new Linux boot or FPGA synthesis is
part of this symbolic refactor.
