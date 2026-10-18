# ADR 0002: Serialize atomics before one shared physical cache

Status: **accepted on `multicore-support`**, reconstructed from implemented
code and its documentation at `f655debae`, 2026-10-18. Not adopted on
`main:3585ff04e`; no claim that a historical formal ADR review occurred.

## Context and alternatives

Stage 2 (`17fcce818`) already serialized uncached harts and tracked physical
LR/SC reservations centrally. Stage 3 needed coherent instruction/data
visibility and a Linux SMP platform. Retaining uncached execution remains the
baseline. Private caches with a snooping/MESI protocol are an alternative but
are not implemented or quantitatively compared in the recovered work.

## Selected approach and rationale

Place one optional unified, direct-mapped physical cache **after** the central
reservation/AMO arbiter. All harts' accesses, including cache hits, traverse
the same serialization point. Read allocation fills a complete aligned bus
word; write-through writes invalidate a matching line and complete after the
downstream response. Only RAM/external memory is allocated; ROM/MMIO bypass.
This supplies one physical copy without private-cache coherence machinery.

For the shared-cache derivatives, disable Svadu and use software PTE A/D
updates (Svade): the current walker update is not an inter-hart atomic PTE
operation. Disable Svpbmt because the cache selects RAM by physical address
and does not receive PTE memory attributes. Cache-maintenance extensions are
disabled in these derivative recipes.

## Affected code and compatibility

At the pinned revision: `src/ebu/{ahbmulticore,ahbsharedcache}.sv`,
`src/wally/wallypipelinedsoc.sv`, the existing core/LSU atomic integration,
`config/derivlist.txt` (`multicore_atomic`, `multicore_coherent`,
`multicore_linux`), `tests/multicore/`, and `linux/smp/`.

`NCORES=1, SHARED_CACHE=0` preserves the original direct path; enabling the
cache also uses the central arbiter for a single hart. Default cache size is
256 bus words (2 KiB in RV64). Guards reject private memories/caches and
bursts in the shared-bus configuration. Serialization and write-through
traffic limit bandwidth; no general scaling or performance improvement was
established. Writers bypassing the arbiter, including external DMA, are
outside the coherence contract. FPGA area/timing remains unverified.

## Verification and source evidence

Required checks: cache hit/miss/subword/MMIO/error/reset behavior; LR/SC
invalidation and AMO exclusion; inter-hart code modification plus `fence.i`;
memory/IPI/timer tests under waits; uncached single-hart compatibility; lint;
and Linux processes with CPU affinity and shared counters. Observed scope and
gaps are in the [Linux SMP record](../experiments/2026-10-18-linux-smp.md).

Pinned [SoC wiring/guards](https://github.com/antoniofloresgil/cvw/blob/f655debaed2bda8dfa7635d1a78a8f32f66bffa7/src/wally/wallypipelinedsoc.sv),
[cache RTL](https://github.com/antoniofloresgil/cvw/blob/f655debaed2bda8dfa7635d1a78a8f32f66bffa7/src/ebu/ahbsharedcache.sv),
and [existing branch explanation](https://github.com/antoniofloresgil/cvw/blob/f655debaed2bda8dfa7635d1a78a8f32f66bffa7/tests/multicore/README.md)
are the evidence. Inspect locally with `git show f655debae:<path>`; do not
copy this architecture onto main without integration and verification.
