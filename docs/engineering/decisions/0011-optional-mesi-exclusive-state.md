# ADR 0011: Optional MESI clean-exclusive state

Status: **proposed**, implemented on `multicore-support`, published base
`b72f8852188560c181b8f1bc06e552d497ccf371` plus the working-tree burst extension.
Date: 2026-10-20. The user requested MESI after the burst implementation.

## Context and decision

MSI gives an unshared clean read S permission, requiring arbitration before
its first write even when no other data bank contains that line. Add SoC
parameter `MESI`, default zero, to the existing private-cache topology.
MSI remains available for controlled comparisons. CLI `--mesi` requires
private data caches; Linux uses `--cache-mode msi --mesi` to retain the
existing topology selector. With NCORES=1 the existing generate bypass
removes all private coherence logic even when MESI is requested.

The centralized snooping controller can inspect every private D bank at the
physical address home, so an absent peer establishes clean exclusivity.
No directory, Owned state or new interconnect messages are required.
States retain the existing I=0, S=1, M=2 encodings; E=3 is added.

## Transitions and interfaces

| Event | MESI action |
| --- | --- |
| Successful D read fill without a valid D peer | Requester E |
| Successful D read fill with a valid D peer | Requester S; an E peer becomes S |
| Read hit on E | Retain E |
| Ordinary E write with local writes enabled | Local E-to-M commit, no global request |
| E write with local writes disabled, or atomic write | Existing arbitrated path grants M |
| Successful peer write/upgrade against E | Invalidate E peer and grant requester M |
| Clean E replacement | Discard without writeback |
| Peer read against M | Existing acknowledged writeback, then S sharing |
| Failed peer fill against E | Retain E, requester remains invalid |

E is exclusive among **data** banks. Instruction reads do not allocate data
copies and do not downgrade E. They can leave instruction copies elsewhere;
every local E-to-M store uses the existing reservation and instruction
invalidation broadcast. The entire refill/coherence-region guards that
protect M stores also protect E stores from snooping races. Dirty ownership
is assigned on the same edge as the committed data bytes.

`ahbmsicache` adds peer-presence detection, clean-exclusive allocation and
E-to-S downgrade only at successful data-read completion. Local write probes
accept E as well as M when MESI is enabled. The shared-valid invariant still
requires every pair of matching valid D copies to be S; E and M cannot
coexist with another matching copy. Failed fills never grant E or M.

`MESI` propagates through the one-home controller, multi-home fabric, SoC,
wrappers and testbenches. No change to `cvw_t` is needed: this follows the
existing elaboration-time SoC coherence options. Linux manifests, compiled
model fingerprints, executable directory names and checkpoint identities
carry the flag; explicit mismatches are rejected. Cache capacities and DTB
bytes are unchanged; the OS does not select the hardware protocol.

## Alternatives, verification and limits

Replacing MSI outright would remove a useful regression/performance baseline.
Adding Owned would address dirty sharing rather than the unshared first-write
cost and would require additional dirty responsibility rules. Both are
outside this change.

The [experiment](../experiments/2026-10-20-mesi.md) records directed transition,
random reference, full-core, negative-control and lint results. Linux requires
a fresh frozen model and its own result. Earlier MSI and burst Linux results
are not MESI validation. Same-home serialization, globally exclusive AMOs,
one pending CPU request per hart, one physical AHB port and lack of coherent
external DMA remain. No FPGA timing, area, BRAM inference or DDR3 performance
result is implied. Proposal status is not promoted by passing simulation.
