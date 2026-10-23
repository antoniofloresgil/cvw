# Experimental multicore capability and integration contract

Scope: the optional memory subsystem on `multicore-support`, recommendation 7
on parent `1a40aaac2`. This scopes the experimental multicore additions; it does
not replace the upstream/native single-core verification or FPGA documentation.
Machine-readable definitions live in
[the profile schema](../../../config/multicore/schema.json), `capability_contract`.

## Availability versus evidence

A legal parameter tuple satisfies elaboration constraints. It is not automatically
a tested configuration or a qualified platform. The CLINT addressable hart range
is a register-map limit. The Linux recipe's 1..8 range is an image-builder limit.
Neither is evidence for that many functioning harts. Overrides of a named profile
also require their own execution evidence.

| Path/profile | Implemented scope | Evidence and remaining boundary |
| --- | --- | --- |
| Native single-hart bypass / `default` | Original core path; outside the new hart-port ordering contract | Native verification remains separately scoped; this report makes no new native FPGA claim |
| Buffered uncached / `stress` | Hart requests share the ordering/reservation point; no private write-back data | Ordinary CI executes RV64 full cores at 1/2/3 harts and RAM latency 0/3; transport fixtures separately exercise RV32/RV64 |
| `ci-msi` | Private MSI, one home, I banks, local D paths and forwarding | Exact 32-word/four-word-line CI configuration, 2/3 harts; not every option combination or deployment capacity |
| `ci-mesi-banked` | Private MESI, two homes, bursts, I banks and local D paths | Exact CI configuration at 2/3 harts; physical memory remains a shared port |
| `linux-shared` / `linux-msi` | Bounded RV64/Sv39 image recipe and effective RTL/DT/manifest consistency | Image generation/model compilation is not a boot verdict; historical two-hart boots retain their original source/configuration scope |

Controller units cover additional RV32/RV64 and geometry cases; read their actual
result records. Current revision-specific CI manifests attach validation_scope
with executed full-core counts/widths/latencies and explicit NOT RUN Linux/FPGA
scope. A PASS from a transport fault-injection fixture establishes only its named
transport/state invariant. No arbitrary-hart, general external-master coherence,
precise CPU bus-error recovery, or multicore FPGA qualification follows.

`profiles.py --describe` reports availability and limits, with a distinction
between topology-only validation and actual core/topology validation. Effective
configuration reports and Linux manifests carry the same canonical capabilities.
`--require-capability <name>` rejects unsupported/unverified properties before
building. A forged or stale capability report is rejected when generating a DT.
These requirements describe existing properties; they do not enable hardware.

## Current coherent domain

Every writer to shared coherent memory must traverse the buffered hart path and
its ordering/coherence machinery. This includes local modified/exclusive stores,
which notify reservation and instruction invalidation logic. RAM changes outside
that path are invisible to those mechanisms.

The SoC external AHB connection exports transactions toward an external slave.
It is not a coherent DMA ingress. An independent DMA/debug/bus master writing RAM
behind the fabric can leave private/shared caches stale, fail to invalidate LR/SC
reservations and race AMO exclusion. These limitations also matter in uncached
mode: removing caches does not make bypassed reservation/AMO logic observe writes.
No DMA-coherent device-tree property or driver API is provided by these profiles.

A fence alone does not flush/invalidate caches or notify reservations about an
external write. The private-cache profiles reject cache-maintenance extensions;
Svpbmt is disabled and the cache allocation predicate uses physical RAM regions.
A different virtual alias or ordinary software cache-maintenance recipe therefore
cannot be assumed to make DMA safe with this implementation.

## Required design before integrating an external writer

A future coherent ingress must identify external requesters separately from hart
IDs and define acceptance, completion, outstanding-request bounds and backpressure.
Its operations must visit the correct home, obtain current modified data, acquire
write permission and invalidate relevant copies before ownership is acknowledged.
All committed writes must notify every affected LR/SC monitor and instruction bank.
Cross-home requests must respect global AMO exclusion and the platform's ordering
rules. DMA completion must mean data/invalidations are visible, not merely queued.
Define reset, error and partial-write semantics for that ingress too.

A deliberately noncoherent design instead needs an explicit physical memory policy
and buffer ownership protocol. Isolate buffers from every allocating cache, define
how reservations/atomics are excluded or notified, and prevent CPU/external access
races. If cache maintenance is needed, implement and verify it first. Neither this
uncached-region mechanism nor a coherent ingress is implemented by this change.

Acceptance requires directed external read/write versus dirty-owner tests, local
store/refill races, LR/SC byte/granule conflicts, AMO exclusion, independent homes,
wait/error/reset cases and CPU/device visibility checks. Record exact target,
source and configuration. Current hart-only tests do not meet this criterion.

## HRESP and dirty writeback errors

| Event | Existing transport behavior | Architectural boundary |
| --- | --- | --- |
| Read/fill error | Local two-cycle ERROR; failed fills do not become valid | EBU currently ignores HRESP for precise CPU access-fault delivery |
| Store/SC/AMO error | ERROR is routed; SC result/lock recovery follow the bus contract | A failed response is not a rollback guarantee or proof of correct continued CPU execution |
| Dirty eviction/intervention error | Modified owner/data are retained; no permission change contingent on a successful full writeback | Earlier acknowledged beats may already have changed RAM; there is no automatic retry or platform error ABI |
| Reset | Buffered work/locks/reservations/validity reset | Committed writes are not undone; dirty cache contents are not promised to survive reset |

The [bus contract](core-bus.md) specifies the transport phases. Error-injection
slaves model a failed beat as not committed; earlier successful beats can persist.
A real slave's write-on-error semantics must be specified before architectural
recovery can be designed. Current state-machine recovery is not qualification for
continued coherent CPU execution after an error.

Experimental SoC and Linux full-core harnesses require fault-free bus operation.
A simulation guard stops on downstream HRESP or any hart-side HRESP outside reset,
including locally rejected operations. Ordinary failed SC is an OKAY response with
SCFail and remains allowed. Error-injection unit/adapter tests remain separate and
continue checking ERROR routing, retained dirty ownership and lock recovery.
The guard does not generate traps or alter hardware recovery.

## Required design before architectural bus-error support

Define an explicit error response back to IFU/LSU/walker with request identity,
physical address, operation/size and originating instruction context. Preserve that
identity through buffering, AMO halves, refills, waits and errors. Define pipeline
stall/flush/retirement behavior and prevent a failed operation from being treated
as successful data/write completion. Page-walker faults need their initiating
instruction context, not an unrelated bus address or fetch response.

Choose a separate platform policy for failed dirty writebacks: they may represent
already retired stores, so simply faulting the current miss is not a complete
precise-error design. Specify retained ownership, partial memory effects, retry or
fatal/deferred reporting, observability and recovery/reset behavior. A retry policy
must not duplicate device side effects. Error reporting must not silently discard
the only dirty copy. These choices need an accepted design before implementation.

Acceptance requires CPU-level fault/retirement checks for instruction/data/walker
requests, load/store/LR/SC/AMO, each refill/writeback beat, owner association,
partial effects, dirty-data preservation and repeated error/reset behavior.
Transport ERROR tests alone cannot qualify this property.

## FPGA and scaling qualification

For a multicore FPGA claim, record an exact board/part, clock and constraints,
RTL/configuration/bitstream identities, resource/inference reports, routed timing,
and actual multi-hart boot/interrupt/atomic/coherence results. RTL Linux success
cannot substitute for those artifacts. No such new qualification is supplied here.
For each claimed hart count, execute appropriate peripheral/context, ordering,
reservation, coherence, progress and software tests at that count. Parameter
addressability or generation of a device tree is not a scaling result.
