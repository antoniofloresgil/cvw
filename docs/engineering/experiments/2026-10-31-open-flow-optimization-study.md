# Open FPGA flow optimization study (RV64GC, Nexys Video)

Date: 2026-10-31. Branch `opensource-fpga-bitstream`, sources at `0d21b2fff`,
configuration `fpganexysvideo`, Wally at 12.5 MHz (LiteDRAM CDC, VexRiscv service
CPU kept). Tools: Yosys 0.69+152 with yosys-slang, openXC7 nextpnr-xilinx 0.9.8
with the local LUTRAM/clock-inversion patch, `fix-carry4-outputs.py`.

Status: **measurements only, no change applied.** The user decided to leave the
design as it is and keep these results for a later optimization pass. No
bitstream was built from the variants below and nothing here was run on the
board. All frequencies are nextpnr estimates (`Max frequency for clock 'HCLK'`)
after place and route.

## Question

The Linux design reaches 13 to 15 MHz in nextpnr against a 12.5 MHz target (the
Vivado flow runs the same RTL at 20 MHz). What limits it?

## Findings

1. **Timing is routing-bound.** The critical path of the Linux build (13.30 MHz)
   was 75.2 ns: 5.3 ns of logic and 69.9 ns of routing, 42 hops, crossing the
   device several times. Vivado's worst path is about 49 ns with 50 logic levels.
2. **Area is about 1.4x Vivado's in logic LUTs, not 1.8x.** An earlier
   hierarchical Yosys run over-counted: it kept module boundaries, and an
   address register left in a separate module stopped Yosys from inferring
   block RAM. Per unit, with module boundaries kept only at unit level:

   | Unit | Yosys LUTs | Vivado LUTs |
   |---|---|---|
   | FPU | 15.9k | 10.7k |
   | LSU | 12.6k (+828 RAM64M) | 9.8k |
   | IFU | 11.4k (+748 RAM64M) | 7.9k |
   | IEU | 10.8k | 6.5k |
   | Core | 57.2k (+1576 RAM64M) | 40.3k (64 RAMB36 + 34 RAMB18) |

   Largest contributors in Yosys: bitmanip ALU 5.9k, `fdivsqrt` 5.2k, `csrc`
   (HPM counters) 3.7k, each TLB 3.3k, each PMP checker 2.0k, `fregfile` 3.2k.
3. **Caches map to LUTRAM, not block RAM.** The BTB and the PHT already use
   block RAM in the flat build. Cache data and tag arrays (40 memories of depth
   64) become RAM64M: about 6.3k LUT-equivalents that Vivado puts in BRAM.
   Isolated test of one 64x128 subarray: the current write-first read pattern
   forced to block RAM costs 2 RAMB36 plus about 135 FF and 134 LUT of bypass
   logic, worse than LUTRAM in LUTs. A read-first registered output
   (`always_ff ... if (ce) dout <= RAM[addr]`) maps to 2 RAMB36 with no extra
   logic. Whether the caches tolerate read-first semantics was **not checked**;
   it needs simulation first.
4. **Denser placement does not help.** `NEXTPNR_PLACER_BETA` 0.6 and 0.8 gave
   pre-route estimates of 10.77 and 10.54 MHz against 12.34 MHz for the default,
   and neither finished routing in over 24 hours (8 270 and 90 000 overused
   wires). Both were stopped.
5. **The 29 HPM counters cost about 1.7 MHz and routing stability.** Rebuilding
   with `COUNTERS = 12'd3` (only `mcycle`, `time`, `minstret`; a copy of the
   configuration, not committed):

   | Netlist | Seed | Pre-route | Final | Routing |
   |---|---|---|---|---|
   | base | default | 12.90 | not converged | stuck at 392 overused wires after 9 iterations (stopped) |
   | base | 2 | 12.28 | 13.64 | 3 iterations, 13 min |
   | no HPM | default | 13.14 | 15.10 | 2 iterations, 10.5 min |
   | no HPM | 2 | 14.49 | 15.32 | 3 iterations, 11.5 min |

   Packed SLICE_LUTX: 85.7k (base) against 79.8k (no HPM). The base netlist
   has one converged seed only, so the 13.64 MHz figure is a single measurement.
6. **The limit moves, it does not disappear.** Critical paths seen:
   - Linux build: `PTE[57]` to a flop beside the `csrc` counters (75.2 ns).
   - base, default seed: `Spill.CurrState` (IFU spill FSM) to
     `HPMCOUNTER_REGW[16][63]` (event `ICacheAccess` through the 64-bit
     incrementer).
   - no HPM: `PageType[2]` to `icache.vict.cacheLRU.CurrLRU[2]` (66 ns, 44 hops):
     MMU/HPTW logic to the I-cache LRU through the stall network.

## Options considered, not done

- **Lower `COUNTERS` for `fpganexysvideo` only.** No shared RTL change; about
  +1.7 MHz and easier routing. Cost: no hardware performance events for `perf`.
  Linux itself does not need them.
- **Register the HPM events one cycle in `csrc.sv`** (counters 3 to 31), keeping
  the counters. Cuts the event-to-incrementer path; changes shared RTL, so it
  needs `regression-wally` and the coverage tests. Not measured: the area stays
  at the base netlist's size, so the gain may be smaller than removing them.
- **Read-first cache RAM** to get block RAM. Needs a simulation check of cache
  behaviour and probably a change in `src/generic/mem/`.
- **Restructure the MMU/HPTW to cache-LRU path** (pipeline or localize it). Larger
  RTL work, and the next limit after the HPM counters.
- Remaining untried levers: more seeds on every variant, `NEXTPNR_PLACER_BETA`
  below 0.4, and ABC9 and DSP review.

## How to repeat

Build the sources for `fpganexysvideo` (`make PreProcessOpenSource
OPENCONFIG=fpganexysvideo`, then `./gen-litedram.sh --user-data-width 64
--user-clk-freq 12500000`), synthesize as `build-opensource.sh` does (with
`scratchpad -set abc9.verify 0`, `synth_xilinx -flatten -arch xc7 -abc9` and
`prepare-nextpnr.ys`; about 5 minutes and 2.7 GB), run
`fix-carry4-outputs.py`, then `nextpnr-xilinx --freq 40 --timing-allow-fail
--seed N`. Run at most two P&R jobs at once (about 3 GB each when routing). For
the HPM variant, copy `config.vh` and set `COUNTERS = 12'd3`.
