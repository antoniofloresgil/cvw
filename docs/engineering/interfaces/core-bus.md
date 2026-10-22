# Wally buffered core/bus contract

Scope: `multicore-support`, implementation on parent `8ecb9ef1b` under
proposed [ADR 0016](../decisions/0016-core-bus-temporal-contract.md). This
contract describes the port **after EBU**, before ahbmulticore or ahbmsifabric.
The default single-hart bypass remains the native upstream AHB connection;
these additional buffered-port rules/checkers are not inserted in that bypass.

## Clock, acceptance and ownership

All signals use HCLK; reset is active-low, synchronous in the adapters. Hold
HRESETn low across at least one rising edge and reset the associated downstream
slave with it. While reset is asserted, no local acceptance or downstream
transfer is permitted. Old responses, reservations and AMO ownership do not
survive that reset.

At each rising edge, `CoreHREADY[h] && CoreHTRANS[h][1]` accepts an address for
hart h. Capture HADDR, HSIZE, HPROT, HWRITE and HATOMIC **at this edge**. Only
NONSEQ (`10`), SINGLE (`000`) and CoreHMASTLOCK=0 are supported. There is one
outstanding request per hart. An edge with HREADY high can simultaneously
retire the previous request and accept its successor.

An available port advertises HREADY independently of HTRANS. Wally busfsm
qualifies initial HTRANS with HREADY; gating idle HREADY by HTRANS or a prior
grant would form a combinational dependency or deadlock. EBU also saves the
IFU's address when IFU and LSU request together; the shared port observes the
arbitrated/saved request, not the IFU's original issue edge.

After acceptance, the adapter owns the captured metadata. The producer may
present another address or change HATOMIC while waiting; neither changes the
accepted operation. The producer does not need to keep HTRANS high while
waiting. Read responses belong to the captured hart/request, not the live
address inputs or the next arbitration candidate.

## Write-data lifetime

Address and write data are different phases. ahbinterface registers WriteData
and ByteMask one cycle after address issue, and EBU forwards that LSU data.
The value on the address-acceptance edge can still belong to the previous
transaction. Do not capture it as this request's data.

| Edge / interval | Producer | Adapter |
| --- | --- | --- |
| A: ready && NONSEQ | Present address/control/HATOMIC; old write data is allowed | Capture metadata; mark hart pending |
| First data edge after A | Present this write's HWDATA/HWSTRB | Data is now valid, including a possible early local completion |
| Subsequent pending edges | Keep the entire data word and strobes unchanged | May queue, arbitrate, perform cache/local write or wait on memory |
| R: pending && ready | Old request's data is still valid; next address may be accepted | Reply completes old request; select data using its owner |
| After R | Next write's data may replace old data | No further use of the completed request's live payload |

Live data and strobes remain routed from the data owner until its reply, even
when another address is visible. Local modified-cache stores consume exactly
that same payload. The checker's first data sample is deliberately after A,
and its stability check includes R. It never imposes metadata stability on the
live core address while waiting.

Stability comparisons use case equality so unchanged X bits in unused write
lanes or failed-read data do not become a requirement for defined data in a
four-state simulator. This does not make failed-read data architecturally valid.

## Atomic sideband and exclusion

| HATOMIC | Meaning at accepted address |
| --- | --- |
| 00 | Ordinary load/store or IFU access |
| 01 | LR read |
| 10 | SC write |
| 11 | AMO read or its paired AMO write, distinguished by HWRITE |

LR must be a read; SC must be a write. EBU drives zero atomic metadata when
selecting IFU, even if LSU is stalled on an AMO. In supported profiles the LSU
has already suppressed CPU atomic tagging for walker accesses. HATOMIC belongs
to the address phase and is buffered with it; HMASTLOCK is generated downstream,
not driven as a core-side lock request.

An AMO read acquires exclusion when admitted to the global engine. A banked
fabric drains previous active transactions before admitting it. Only that
owner can initiate global requests while the lock is held. Owner IFU/LSU
requests can make progress between read and write; unrelated private I hits
need not consume a global grant. Other harts can queue addresses, but cannot
dispatch global work or commit local M stores through the AMO lock.

The paired write must use the same physical address and size as its locked
read. It releases the lock on success or error. A failed AMO read also releases
the lock; any follow-on orphan AMO write is rejected locally with ERROR and
never reaches memory. Reset releases ownership. There is no implicit timeout
or lock release merely because the producer idles: an owner that never sends
its write can block peers until reset. No bounded progress is promised without
a completing slave and a conforming AMO producer.

## LR/SC and retained results

LR records its physical address and size only after a successful completion.
SC is revalidated at global ordering, not when the core address is buffered.
It requires matching address/size and a still-valid reservation. All SC
attempts consume the reservation, including failures. Successful global/local
stores to the XLEN-word reservation granule invalidate it; a new LR replaces
the previous reservation. Banks coordinate clearing so reservations belong to
harts, not to homes.

A failed SC is an OKAY local completion with CoreSCFail=1 and no downstream
write. A successful SC has CoreSCFail=0; a downstream SC error has HRESP and
CoreSCFail=1. CoreSCFail may update while that SC is completing (including its
first ERROR phase), and must be correct at its final ready edge. It then stays
unchanged across IFU/ordinary/other-hart replies until the next completing SC
or reset. This retention is needed when memory retirement waits for IFU.

## Errors, flush and aborts

The adapter translates a failed downstream completion into two local cycles:
HRESP=1/HREADY=0, then HRESP=1/HREADY=1 with the same response data. The latter
retires the request; a subsequent idle cycle clears HRESP. Successful replies
have HRESP=0. Local orphan-AMO rejection follows the same two-cycle sequence.
Errors do not establish LR reservations or complete successful writes, and
release AMO ownership as described above.

The present EBU/busfsm ignores HRESP for architectural exception generation.
Releasing a lock or returning an ERROR is **not evidence of a precise CPU
access fault**. A cache writeback error also cannot promise transactional
rollback of older effects. The port contract specifies response routing and
recovery, not a new architectural trap mechanism.

Flush prevents pre-issue busfsm requests. There is no cancel/kill signal at
the buffered port after an address has been accepted: a live request must
drain, with its payload retained, even if higher-level control changes. A core
change that permits an in-flight flush to drop or alter that payload violates
this interface and needs a separately designed abort mechanism. Reset can
discard accepted work; it cannot roll back a write committed before reset.
Dirty private-cache data is not guaranteed to survive reset.

## Executable checks and limits

`corebus_contract` monitors accepted operations, data/strobe lifetime, LR/SC
direction, two-cycle ERROR and retained SC status on each bridge and at the
banked fabric's outer port. Bridge/fabric assertions additionally check stable
downstream ownership during waits, AMO grant/dispatch/local-store exclusion,
paired AMO address/size and rejection without a downstream transfer.
Monitor state is inside synthesis translate-off regions; no payload register,
new interface signal, functional state transition or bypass latency is added.

`adapter_tb` uses actual ahbinterface/busfsm/EBU modules, with two/three harts,
RV32/RV64, one/two homes, latency 0/3, simultaneous IFU/LSU and competing harts.
It checks delayed write data, changed live metadata, partial writes, SC retention,
AMO exclusion, error phases and reset while an AMO write is pending. Negative
fixtures must trigger specific assertion messages. Existing synthetic
back-to-back/atomic/coherence benches and full-core CI supplement these tests.
See the [verification record](../experiments/2026-10-21-core-bus-contract.md).
These checks are simulation assertions and directed tests, not a formal proof
or a generic AHB conformance suite.


The [capability and integration contract](multicore-capabilities.md) scopes
hart-only coherent writers, transport-only error recovery, dirty-writeback effects
and the prerequisites for future DMA/architectural-error support. Experimental
full-core SoC/Linux harnesses require fault-free execution and stop on HRESP;
transport fixtures retain deliberate error injection. Parameter legality and
transport PASS do not qualify FPGA, arbitrary hart counts or CPU trap delivery.
