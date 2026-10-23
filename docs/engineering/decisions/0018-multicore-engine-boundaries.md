# ADR 0018: isolate multicore reservation and cache storage responsibilities

Status: **proposed**; implemented on `multicore-support` parent `349263f55`.
Implementation and passing tests do not automatically accept the decision.

## Context and proposed choice

Recommendation 6 identified reservation, arbitration, instruction storage and
coherence/data storage concerns within the same engines. Recommendation 5 already
centralized physical memory policy; reuse that policy rather than moving it again.

Extract hart-owned LR/SC state and sticky SC results into `multicore_reservations`,
with issue/completion/clear/local-store events at the existing ordering point.
Keep AMO lock control with bridge scheduling. Extract per-hart instruction arrays,
tags and validity into `multicore_icache_bank`; keep refill sequencing and hazard
checks in `ahbmulticore`. Extract bulk data words and byte/line writes into
`multicore_dcache_data`; keep MSI/MESI metadata, decisions and transaction buffers
in `ahbmsicache`. Document the [event and storage contracts](../interfaces/multicore-storage.md).

Preserve edge priorities and zero-cycle combinational reads. The native single-hart
bypass, public SoC parameters, core ports and memory ordering are unchanged. Test
source lists explicitly include helper dependencies; all-source flows discover
the new modules automatically. Existing full-core data observers use a passive
simulation-only alias without adding a hardware array interface.

## Alternatives and consequences

Extracting the entire arbiter/cache controller in one rewrite would mix structural
changes with protocol changes. Deferring storage timing until a BRAM replacement
would hide read/write bandwidth and latency assumptions. Adding a synchronous RAM
mode now would change hit/reply scheduling and require separate architecture work.
Sharing raw arrays through synthesizable module outputs would defeat a useful
storage boundary. Keep explicit ports instead, and leave general test observation
adapters to recommendation 9.

The extracted data port combines word-source selection where consuming controller
states are disjoint, and retains the old line-wide bandwidth. Tags and permissions
remain controller state; this is an incremental boundary, not a claim of fully
independent nonblocking L1 controllers. No new supported topology, DMA coherence,
precise CPU bus exception handling or RAM technology is introduced.

## Verification

Run isolated RV32/RV64 engine fixtures and the existing four CI profiles, compare
program cycle/traffic signatures against parent-source evidence, and exercise
one-word private lines and the one-hart shared-cache monitor path separately.
Preserve real adapter/error/SC/AMO checks. See the
[implementation record](../experiments/2026-10-22-multicore-engine-extraction.md)
for exact verdicts, hashes and missing evidence. BRAM inference/resource/timing
and hardware boot remain unverified.
