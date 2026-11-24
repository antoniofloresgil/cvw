# 0025. Multicore private caches in block RAM

Status: **accepted** (2026-11-24). Applies to the SoC's multicore memory system (`src/ebu/`): the private MSI/MESI data
caches (`ahbmsicache.sv`, `multicore_dcache_data.sv`) and the private instruction caches (`ahbmulticore.sv`,
`multicore_icache_bank.sv`).

## Context

The first two-hart build of the Nexys Video (`fpganexysvideosmp`, 2026-11-23) with 8 KiB private caches per hart and
4-word lines needed 514k LUT, 382 % of the XC7A200T, and only 21 block RAMs. The data arrays read combinationally and
each hart's array had several ports at once: the hart's local read, the controller's word read and full-line read
(of any hart), installation of a whole line, the global store and the hart's local store. Block RAM has registered
reads and two ports, so Vivado built the arrays from flip-flops and multiplexers; `ram_style` cannot change that. The
board therefore ran with 512-byte caches, which also made the timer tick of the board's `HZ=250` kernel take all the
time of both harts (`docs/fpga-multicore.md`).

## Decision

1. **Data: one-word banks, a line per access.** Each hart's data cache is `LINE_WORDS` banks of one word
   (`ram2p2rwbe`, a new true dual-port RAM with byte enables after Vivado's template), all at the same line index,
   so a line is read or written in one access. Port A belongs to the hart (local read, local store); port B to the
   controller (line and word reads of every hart's line at the controller's address, the owner's installation merged
   with the global store's bytes). Tags and coherence states stay in flip-flops: the snoop reads them for every hart
   in the same cycle.
2. **Instructions: one RAM per hart** (`ram2p1r1wbe`, read port for the hart's probe, write port for the refill);
   tags and valid bits stay in flip-flops.
3. **No added latency.** Both request registers (`Addr` of `ahbmulticore`, per hart, and `Addr` of `ahbmsicache`)
   take their address one cycle before the old combinational arrays were read. The RAMs are addressed with the value
   the register is about to take (`CacheReadAddrNext`, `AddrNext`: the incoming address when a request is accepted,
   otherwise the held one), so their registered output arrives in the cycle the old read happened. While a register
   holds, the RAM keeps reading its address, so a request that waits sees writes made in the meantime. The owner's
   line is written in `COMPLETE`, where the controller's address cannot change; a local store commits while its
   hart's request is pending, where its address cannot change either (both are asserted in simulation).
4. **Collisions.** Block RAM leaves undefined a read of an address that the other port writes in the same cycle. The
   data module marks such a hart read (`LocalReadValid`), and the I-cache misses for that cycle; the request is
   then served like any other non-local one. By construction this does not happen in the arbiter's flows (the
   controller writes only the owner's lines, and the owner has no local request meanwhile); the guard makes it safe
   regardless. The controller's own reads cannot collide with a local store to the same line: the arbiter already
   forbids local stores that race a global access to their line.

## Consequences

- Vivado maps one hart's 8 KiB data cache and 8 KiB instruction cache to 10 RAMB36 and 64 LUT (out-of-context
  synthesis, 2026-11-24): 8 for the four 64-bit data banks (true dual port is at most 36 bits wide), 2 for the
  instruction RAM.
- Verified: the multicore matrix (`tests/multicore/ci.py --case all`), the storage contracts of `engines_tb.sv`
  (updated to the one-cycle read, including the collision case), and Linux SMP on the RTL with two harts and 8 KiB
  private caches (`linux/smp/run.py`): `WALLY_SMP_PASS` after 352 M cycles, against 465 M with the old 512-byte
  caches.
- The passive observers of `tests/multicore` keep their flat view of the arrays (`Lines`), rebuilt from the RAMs in
  simulation only.
- Next: a Nexys Video build of `fpganexysvideosmp` with 8 KiB private caches, then the board.
