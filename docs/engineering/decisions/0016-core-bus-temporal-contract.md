# ADR 0016: explicit buffered CPU/bus temporal contract

Status: **proposed**; implemented on `multicore-support` parent `8ecb9ef1b`.
Implementation/testing does not automatically change this decision's status.

## Context and proposed choice

Recommendation 4 of the [maintenance review](../experiments/2026-10-21-multicore-maintainability-review.md)
identified implicit ready-dependent issue, delayed/live write payloads, atomic
metadata, retained SC results and error/abort assumptions at the CPU boundary.
Observed Linux boot alone cannot guard those assumptions against busfsm changes.

Make the [core/bus interface contract](../interfaces/core-bus.md) authoritative
for the supported buffered SINGLE port. Preserve the existing datapath and
native single-hart bypass. Add a simulation-only reusable port checker in
ahbmulticore and ahbmsifabric, plus engine assertions for ownership/AMO rules.
Add directed endpoints using the real ahbinterface/busfsm and EBU, rather than
only synthetic masters, and select their RV32/RV64, 2/3-hart, one/two-home tests
and negative assertion fixtures in the existing per-change matrix.

## Alternatives and consequences

Capturing write data together with the address would capture the previous
transaction's data because ahbinterface registers the payload one cycle later.
Adding a separate hardware payload stage could decouple lifetime, but changes
latency/state without a demonstrated need and would require separate design
and performance validation. Leaving the rules in comments would not detect
producer drift. Generic AHB VIP alone would not capture Wally's ready-qualified
issue, shared atomic sideband or sticky SC result requirements.

The chosen monitors add simulation state only, excluded from synthesis. No core
port, cvw_t field or pipeline stall/flush behavior is changed. Assertions require
`--assert`; directed tests have finite simulation limits and negative cases
require the named diagnostic, not any generic process failure. ERROR routing
remains separate from precise CPU exception delivery; there is no new cancel
signal or rollback promise after acceptance.

## Verification

Use `tests/multicore/check_boundary.py --negative --work-dir <directory>` after
setup, plus `regression-wally --multicore` and standard lint. The bus CI case
selects one home and negative fixtures; mesi-banked selects two homes. All
existing assertion-enabled full-core/coherence tests also instantiate the
monitors. See the [execution record](../experiments/2026-10-21-core-bus-contract.md)
for observed results, source hashes and limitations. No FPGA or formal result
is implied by the interface definition.
