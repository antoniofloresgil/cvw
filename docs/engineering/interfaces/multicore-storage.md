# Multicore reservation and storage interfaces

Source scope: recommendation-6 implementation on `multicore-support` parent
`349263f55`. These interfaces preserve the current common-clock, blocking-core
[bus contract](core-bus.md). They do not specify a BRAM implementation or a
nonzero storage latency mode.

## Ownership

| Module | Owns | Caller retains |
| --- | --- | --- |
| `multicore_reservations` | Per-hart reservation valid/address/size and retained SC result | Request buffering, scheduling, global ordering, AMO lock, bus replies |
| `multicore_icache_bank` | Per-hart instruction tags, validity and word storage | Refill sequencing/beat count, request suppression, hazard and AMO rules |
| `multicore_dcache_data` | Per-hart data words and byte/line writes | MSI/MESI tags/permissions, snooping, transfer/fill buffers, replies and ordering |

The physical cacheability function remains `multicore_cacheable` from
`config/shared/multicore-memory.vh`. Deployment/profile validation remains in
[the shared configuration policy](../../../config/multicore/README.md). There is
no second memory map or topology definition in these modules.

## Reservation events and priority

All inputs belong to one clock domain. Query owner/address/size are buffered
physical request metadata; `SCValid` is combinational and includes `QueryBlocked`,
a caller-supplied same-cycle ordering hazard. It is evaluated again when a request
is selected, not when the original core address is accepted.

`Issue` means the global ordering point selected this request. It consumes an
LR/SC reservation; a rejected SC sets that hart's retained failure result.
`Complete` describes a downstream completion, including errors; the caller supplies
its owner, physical address, size, atomic operation and direction. The current
bridge emits at most one of Issue/Complete per edge. Neither event is a new queue
or bus handshake. A successful LR installs its address/size; a completed SC replaces
its retained result. Ordinary/IFU replies leave that result unchanged.

On a rising edge, priority is reset, otherwise issue consumption, completion
updates/invalidation, per-hart cross-home clear, then committed local stores.
Reservation granularity is XLEN bytes. Successful global/local writes invalidate
the matching granule, including same-value and partial writes. A local store
coincident with an LR completion compares against the LR's **new** address.
A cross-home clear overrides installation in this home. AMO lock ownership stays
in the bridge/fabric; the reservation module does not schedule or authorize AMOs.

## Instruction storage ports

Each hart has a combinational physical probe returning hit and one data word.
A hit requires cacheable RAM, valid line and matching tag. Data on a miss is not
specified. Tags and data have no reset; reset clears validity only.

The caller sends fill start/error as `FillInvalidate`, successful refill words
as `FillBeat`, and final-beat visibility as `FillLast`. FillAddr identifies the
requested physical line; FillWordAddr selects the word written. Incomplete/error
fills remain invalid. There is one refill word write per edge for one hart.

Committed local stores supply a vector of physical addresses. A successful global
store supplies one address. Both invalidate every matching instruction copy,
including the writer's, at whole I-line granularity. The edge ordering is local
invalidations, fill invalidation, then global-store invalidation or fill word/tag/
valid update. This preserves a simultaneous unrelated refill whose victim's old
tag matches a local store. The caller prevents conflicting local reads/stores
and active refills using the existing mixed I/D geometry guard.

## Data storage ports and read/write behavior

Each data bank exposes one combinational local word read. The controller also has
one selected combinational word port and one selected complete-line port. The
word port serves clean instruction forwarding or the global completion's old value;
the line port serves victim/snoop/forwarding and writeback data. Port selection
belongs to the controller and introduces no registered read stage.

The current logical write interface supports a whole-line install in one edge,
a masked global word store, and one masked local word store per hart. Within an
edge, installation precedes the global byte merge; local updates follow. The
controller excludes local writes to its active global owner's bank. Independent
banks can still commit local writes while another bank performs global work.
A controller sampling read data at the write edge observes the pre-edge value;
a combinational read after the edge observes updated data. Reset inhibits writes
but does not erase data; the controller separately resets coherence permissions.

Existing passive test probes at `ahbmsicache.Lines` are simulation-only aliases of
`data_bank.Lines`, enclosed in synthesis translate-off comments. Functional RTL
uses the explicit ports; no full-array hardware output or second storage copy is
introduced by that alias. Tags and permission probes remain at the controller.
A general simulation observation adapter remains recommendation 9's separate work.

## Requirements for a future RAM implementation

A plain synchronous single/dual-port block RAM is not a drop-in replacement for
these interfaces. The implementation must account for asynchronous local/global
reads, complete-line read bandwidth and whole-line installation bandwidth, byte
masks, and defined fill/store merge priority. Tag/valid/state probes also have
current-cycle timing requirements. Unused combinational values need not be made
architecturally visible; qualifying/scheduling ports may enable a different design.

Before adding synchronous RAM, specify per-bank arbitration and read-valid timing,
then adapt hit replies, fill/writeback sequencing and stalls to that timing. Verify
old-value return, local/global overlap, partial/error fills and reset behavior with
the changed latency. Keep any new mode explicit and independently validated.

This extraction supplies functional/cycle comparison evidence only. No synthesis
resource report, BRAM inference result, frequency improvement or FPGA timing/boot
result was measured or implied.
