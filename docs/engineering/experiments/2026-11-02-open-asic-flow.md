# Open ASIC flow: LibreLane on IHP SG13G2

Status (2026-11-03): **a first chip.** With LibreLane 3.1.0.dev4 and a 40 ns clock, `syn_rv32imc`,
`asic_rv32imc` (4 KiB DTIM in an IHP SRAM macro) and the chip `asic_soc_rv32imc` (Wally's SoC in a
pad ring, booting over the UART) run from RTL to a GDS with LVS, KLayout DRC and antenna clean and
positive slack in all corners; `asic_rv32imc` also closes in SG13CMOS5L. Open: the chip's minimum
metal density (5 windows short), debug access, and the 64-bit core.  The sections up to "SRAM
macro" are the first runs, with LibreLane 3.0.17 at 30 ns; "LibreLane 3.1, the chip and
SG13CMOS5L" has the current ones.

## Setup

- Flow: LibreLane 3.0.17 (Classic, 80 steps), pinned by tag through Nix 2.35.3
  (`nix develop github:librelane/librelane/3.0.17`). Yosys 0.62 with the slang frontend
  reads all of `src/` unchanged; OpenROAD, Magic, KLayout and Netgen come from the same
  environment.
- PDK: IHP SG13G2 (`ihp-sg13g2`), fetched by ciel.
- Design: `wallypipelinedcore` for `syn_rv32imc`, wrapped by
  `asic/librelane/gen_config.py` (the wrapper binds `P` to `config.vh`). Memories are
  flops; there are no macros, no pad ring and no I/O constraints beyond the clock.
- Command: `make -C asic/librelane CONFIG=syn_rv32imc CLOCK_PERIOD=<ns>`.

## Results

| | 20 ns clock | 30 ns clock | 30 ns, final |
|---|---|---|---|
| Magic DRC | 0 errors | 0 errors | 0 errors |
| KLayout DRC | 0 errors | 0 errors | 0 errors |
| LVS (Netgen) | 0 differences | 0 differences | 0 differences |
| Antenna violations | 0 | 0 | 0 |
| Global route / DRT errors | 0 | 0 | 0 |
| Setup slack, slow (1.08 V, 125 C) | **-6.66 ns** | +1.34 ns | +0.42 ns |
| Setup slack, typical (1.20 V, 25 C) | +1.99 ns | +5.09 ns | +4.97 ns |
| Setup slack, fast (1.32 V, -40 C) | +3.41 ns | +6.49 ns | +6.39 ns |
| Hold slack, worst corner | +0.12 ns | +0.10 ns | +0.12 ns |
| Max slew violations, slow corner | 99 | 111 | 2 |
| Max cap violations (each corner) | | | 1 |
| Max fanout violations (each corner) | 776 | 775 | 763 |
| Power (no activity data) | 44 mW | 29 mW | 33 mW |

Common to the first two: die 2.04 mm^2 (1418.8 x 1437.5 um), 82.9k standard cells occupying
1.25 mm^2, utilization 63 %, 9390 flip-flops, 0 power-grid violations. The GDS is 107 MB.
Wall time on a 30 GB workstation: about 4 h with Magic DRC (1 h 37 min of it) and KLayout
DRC (13 min).

With 20 ns the design meets timing in the typical and fast corners only; the slow corner
supports roughly a 27 ns period, so 30 ns is the first round value that closes it.

The final column is the committed configuration (`make CONFIG=syn_rv32imc`): 30 ns, the larger
slew repair margins below and `TIMING_VIOLATION_CORNERS = ["*"]`, so a setup violation in any
corner would have stopped the flow. Die 2.03 mm^2, utilization 63 %, Magic/KLayout XOR 0
differences. It took 2 h 25 min: Magic DRC 1 h 27 min, KLayout DRC 12 min.

## Findings

- The timing checkers fail the flow only for the corners their wildcards match
  (`TIMING_VIOLATION_CORNERS` defaults to `*typ*`; the max slew and max cap checkers match
  none). A violation in the slow corner is a warning followed by "No ... violations found", which
  is why the 20 ns run completed with -6.66 ns. Read `timing__setup__ws` per corner in
  `final/metrics.json`, or make the checkers fatal with `["*"]`.
- The 111 slow-corner slew violations of the 30 ns run were 0.1 % of the cells, driven by `_1`
  drive-strength gates (`o21ai_1`, `nor2_1`, `nor4_1`) with fanout 4-8, up to 3.18 ns against the
  2.507 ns library limit. The resizer repairs with estimated parasitics and the slews grow after
  detailed routing. Raising `DESIGN_REPAIR_MAX_SLEW_PCT` from 20 to 40 and
  `GRT_DESIGN_REPAIR_MAX_SLEW_PCT` from 10 to 30 leaves 2 slew violations (worst 2.551 ns) and 1
  max cap violation (0.328 against 0.300 pF) in the slow corner, with the same area (die 2.03
  mm^2) and 0.42 ns of setup slack there (1.34 ns before). KLayout DRC, LVS and antenna checks
  stay at 0, and so does Magic DRC in the final run. The 775 fanout violations are 98 %
  CTS leaf clock buffers with 15 sinks against a limit of 8, not a design rule.
- `csrm.sv` with `PMP_ENTRIES = 0` declared `PMPCFG/PMPADDR_ARRAY_REGW[-1:0]`, read them and
  never drove them, so Yosys reported 80 check errors and the two runs above had
  `ERROR_ON_SYNTH_CHECKS` off. Fixed in PR #28 (the arrays are driven to zero without PMP); with
  it, the synthesis check of `syn_rv32imc` is clean (`Check for Yosys check errors clear`) and the
  workaround is gone.
- `synthDC/scripts/wrapperGen.py` fails on the multi-line `wallypipelinedcore` header, so
  the open flow generates its own wrapper.
- Magic DRC prints nothing until it ends (1 h 37 min here); the KLayout DRC is the
  reference for IHP.
- Flat synthesis of `syn_rv64gc` is far slower: its ABC step was still running after more
  than 4 h at 14 GB, so no area figure exists yet for the 64-bit core.
- One run was killed by the kernel OOM killer while another large process was using 29 GB;
  `--run-tag <RUN> --from <Step>` resumes from the last completed step.

## SRAM macro

`asic_rv32imc` is `syn_rv32imc` with a 4 KiB DTIM, which `asic/librelane/sram/ram1p1rwbe.sv` puts
in an IHP `RM_IHPSG13_1P_1024x32_c2_bm_bist` macro (placed at 100, 100 um). `make sramsim` matches
the adapter, with the PDK's behavioral model of the macro, against Wally's RAM for 200,000 random
cycles (and fails at once with `A_REN = ~we`). Full flow at 30 ns, 40 min without Magic DRC:

| | `syn_rv32imc` (512 B DTIM in flops) | `asic_rv32imc` (4 KiB DTIM in a macro) |
|---|---|---|
| Die | 2.03 mm^2 | 1.57 mm^2 (macro 0.14 mm^2) |
| Standard cells | 82.9k | 56.7k |
| Setup slack, slow / typical / fast | +0.42 / +4.97 / +6.39 ns | +0.75 / +3.95 / +5.75 ns |
| Hold slack, worst corner | +0.12 ns | +0.10 ns |
| LVS, DRT, antenna, XOR | 0 | 0 |
| KLayout DRC, full deck | 0 | 2672, all inside the macro |
| IHP precheck rule set | | 0 |
| Max slew / max cap violations, slow corner | 2 / 1 | 13 / 2 |
| Power (no activity data) | 33 mW | 17 mW |

The critical path does not go through the macro; the slew violations are in the core logic (worst
3.03 ns against 2.51 ns).

- The PDK's Verilog wrapper of the macro instantiates `SRAM_1P_behavioral_bm_bist`, which is in
  `RM_IHPSG13_1P_core_behavioral_bm_bist.v`; synthesis reads a black box of the macro instead.
- The macro's power pins are on Metal4, and LibreLane's default macro grid connects only the two
  top metals: without one more `add_pdn_connect` (Metal4 to the horizontal straps) the power grid
  check fails (PSM-0069).
- The full KLayout deck reports `Cnt.c.digibnd`, `Sdiod.d` and `Sdiod.e` inside the macro, the same
  counts with or without our logic around it (IHP-Open-PDK issue #793, open). None of the three is
  in IHP's precheck rule set. `check_drc.py` fails on any other violation, on any of them outside
  the macro's cells, and on any precheck violation; an injected violation in our logic fails it.
- Magic DRC reports 2.2 million violations inside the macro: the SRAM rule exceptions are in
  IHP-Open-PDK PR #863 (March 2026), after the PDK that LibreLane 3.0.17 pins (January 2026).
  Magic 8.3.623 is new enough. Magic DRC is off for designs with macros until the PDK is updated.
- Magic's streamout prefixes the macro's cell names with two letters that change from run to run.
  (Superseded: see the next section for the newer PDK, where Magic DRC runs and KLayout DRC is clean.)
- IHP's LibreLane template (`ihp-sg13-librelane-template`, formerly `ihp-sg13g2-librelane-template`)
  has a chip top with a pad ring, SRAM macros with their PDN and a cocotb testbench, for SG13G2 and
  SG13CMOS5L; it adds cocotb to LibreLane's Nix shell.

## LibreLane 3.1, the chip and SG13CMOS5L

LibreLane 3.1.0.dev4 pins IHP PDK 89d42ee, the first with the SRAM rule exceptions for Magic
(IHP-Open-PDK PR #863); LibreLane 3.0.17 cannot load it (its PDK configuration format changed). With
it the KLayout DRC of the macro is clean (no `Cnt.c.digibnd`, `Sdiod.d`, `Sdiod.e` any more) and
stays fatal; Magic still reports about 100 `Cnt.c` / `Cnt.c SRAM exception` inside the macro, which
Magic's author considers real layout errors (IHP-Open-PDK #794, #1024). `check_drc.py` now waives only
those two rules inside the macros' bounding boxes (taken from the final DEF and the LEF), and fails
on anything else (tested by moving the macro: 52 violations not waived).

Other changes in 3.1 that the flow handles: synthesis also reads the I/O pad library (ABC mapped
buffers to `sg13g2_IOPadOut4mA`; `EXTRA_EXCLUDED_CELLS`), slang fails on a missing `$readmemh`
file (`rom1p1r` read `$WALLY/fpga/src/boot.mem`; `gen_config.py` writes a copy that loads the
`--rom` image or nothing; the IROM had never been synthesized before, an empty ROM), and new
synthesis defaults.

### Timing with 3.1

3.1 ships Yosys 0.69 (0.62 in 3.0.17) and makes `SYNTH_STRATEGY` `DELAY 4`, `SYNTH_ARITH_TREE` and
`SYNTH_MUL_BOOTH` the defaults. The cell libraries (0.1.3 to 0.1.4, same delays) and extraction
rules did not change. `asic_rv32imc` at 30 ns, post-route, slow corner:

| | Setup slack | Die | Standard cells | Power |
|---|---|---|---|---|
| 3.0.17, `AREA 0` | +0.75 ns | 1.57 mm^2 | 56.7k | 17 mW |
| 3.1, `AREA 0`, defaults | -8.37 ns | 1.50 mm^2 | 55.1k | 17 mW |
| 3.1, `AREA 0`, no arith tree or Booth | -6.81 ns | 1.54 mm^2 | 56.5k | 17 mW |
| 3.1, `DELAY 4`, no arith tree or Booth | +2.80 ns | 2.37 mm^2 | 90.2k | 25 mW |

(`syn_rv32imc` at 30 ns with 3.1: -7.24 ns.) The pre-route STA of a synthesis sweep is dominated by
unbuffered fanout and does not rank the strategies; only post-route results do. Decision: `AREA 0`
without the two options and 40 ns for every design, rather than 50 % more area and power; the clock
is to be recovered by optimizing the paths (below) later.

At 40 ns (`AREA 0`, the committed configuration):

| | `syn_rv32imc` | `asic_rv32imc` | `asic_rv32imc`, SG13CMOS5L | chip `asic_soc_rv32imc` |
|---|---|---|---|---|
| Setup slack, slow / typical / fast | +4.74 / +7.39 / +8.99 ns | +1.57 / +8.82 / +9.92 ns | +1.16 / +8.34 / +9.59 ns | +3.75 / +13.84 / +15.93 ns |
| Hold slack, worst corner | +0.12 ns | +0.09 ns | +0.09 ns | +0.06 ns |
| Die | 1.99 mm^2 | 1.54 mm^2 | 1.54 mm^2 | 4.00 mm^2 (2.0 x 2.0 mm) |
| Standard cells | 1.23 mm^2, 84.4k | 0.77 mm^2, 56.4k | 0.77 mm^2, 56.5k | 1.00 mm^2, 72.2k (68 % of the core) |
| Routing DRC, antenna, LVS, KLayout DRC | 0 | 0 | 0 (routing, antenna) | 0 |
| Magic DRC | 0 | 109, inside the macro: DRC OK | 106, inside the macro (`Cnt.c`) | 103 inside the macro, 1400 pad-ring warnings: DRC OK |
| Max slew violations, slow corner | 13 | 8 | 15 | 27 |
| Power (no activity data) | 21 mW | 13 mW | 13 mW | 21 mW (1.2 mW before the SDC fix below) |

`asic_rv32imc` in SG13CMOS5L ended clean (KLayout DRC, LVS and XOR 0; `check_drc.py`: DRC OK). Its
routing with two metals fewer takes 2 % more wire and 0.4 ns of slack; the PDN needed one change
(`sram/pdn_cfg.tcl`: the Metal4 connection exists already when the vertical straps are on Metal4).

### The chip

`asic_soc_rv32imc` (`config/derivlist.txt`, from `rv32imc`): no IROM or DTIM; a 512 B BOOTROM at
0x1000 with the bootloader `chip/boot.S`; 4 KiB of RAM at 0x80000000 on the bus, in an SRAM macro;
UART, SPI, GPIO, PLIC and CLINT. `chip/chip_top.sv` follows IHP's template: 20 pads (clock, reset,
UART, SPI, 8 GPIOs, I/O and core supplies), the Chip flow with a core power ring. `make chipsim`
(cocotb, Verilator, with the PDK's pad and SRAM models) loads `chip/test/hello.S` through the
bootloader at a baud divisor of 1 and checks that it prints `OK` and drives 42 on the GPIOs.

- At 30 ns it failed by 6.8 ns: `MExtInt` is combinational from the PLIC's priority registers
  through the trap logic to the 64-bit counters (229 paths, all from `intPriority`).
- The template's 2.2 mm die left the core half empty (49 % utilization); 2.0 mm gives 68 %.
- Power read 1.2 mW: the template's SDC defines the clock on the clock pad's output pin
  (`clk_pad/p2c`), and OpenSTA gives such a pin no clock activity for power; it propagates the
  default input activity of `clk_PAD` through the pad, so the flops looked 15 times quieter.
  `chip/chip_top.sdc` sets two transitions per period on that pin (`set_power_activity`), which
  gives 21.1 mW, the same as a clock on the port; timing does not change.
- Magic reports about 1400 overlaps between the subcells of the pad ring, where KLayout DRC finds
  none; the template removes `Checker.IllegalOverlap` for the same reason. `check_drc.py` turns them
  into warnings outside the core area when KLayout DRC is clean.
- Minimum metal density (`MxFil.h`, 25 % in every 800 x 800 um window; `M2.j`, 35 % of Metal2
  globally) fails in the core:

  | Fill | Violations | Worst Metal2 window |
  |---|---|---|
  | KLayout filler (default), 2.2 mm die | 15 | 16.7 % |
  | KLayout filler, 2.0 mm die | 15 | 17.7 % |
  | KLayout filler with 0.8 um fill spacing (patched copy) | 8 | 18.3 % |
  | Magic filler (`KLayout.Filler: Magic.Filler`) | 5 | 20.4 % |
  | Magic, then KLayout | 5 | 20.4 % |

  The 1 um fill squares need about 1.8 um between routed wires, which Metal2 rarely leaves in the
  standard cell area; filling or shrinking the die more does not fix it. These rules are in IHP's
  precheck rule set (`libs.tech/klayout/tech/drc/docs/precheck_rules.md`), so they must pass.
  The chips now use the Magic filler: with it the chip has KLayout DRC 0, LVS 0 and only the known
  Magic violations, so the filler adds no error. Metal2/Metal3 straps in the core power grid are
  being tried: the PDN connects, and the first routing pass ends clean, but the antenna repair pass
  stops at 32 violations.
- The chip in SG13CMOS5L (`make PDK=ihp-sg13cmos5l CONFIG=asic_soc_rv32imc`, macro at 400, 400, the
  KLayout filler): setup +4.90 / +14.46 / +16.32 ns, hold +0.01 ns, 21.1 mW, routing DRC 0, one
  antenna violation, and 12 density violations (Metal2 18-22 %, Metal3 23-24.5 %, Metal4 17-24 %,
  where the vertical power straps are, and global Metal2 34.2 %).

## IHP open-source shuttles and packaging

As published by IHP on 2026-11-03 ([open-source request page](https://dk.ihp-microelectronics.com/OpenSourceRequest.php),
[schedule and price list](https://www.ihp-microelectronics.com/services/research-and-prototyping-service/mpw-prototyping-service/schedule-price-list));
IHP's pages disagree on some figures, marked (?), to confirm with openpdk@ihp-microelectronics.com.

The open-source MPW runs are low-cost, not free: they are charged per mm² of die.

| Run (tape-in) | Process | Price | Registration until |
|---|---|---|---|
| 14.03.2027 | SG13CMOS5L | 1500 €/mm² | 2027-03-01 |
| 2027, no date given (the schedule lists an OS run on 18.04.2027) | SG13G2 | 2800 €/mm² | 2027-03-29 |
| 08.08.2027 | SG13CMOS5L | 1500 €/mm² | 2027-07-19 |
| 14.11.2027 | SG13CMOS5L | 1500 €/mm² | 2027-10-25 |

- SG13CMOS5L drops to 1000 €/mm² when all customers together request more than 150 mm² (900 €/mm²
  quoted as the lowest price), and a run starts only when 90 mm² are reached; none of the 2027 runs
  had reached it.
- Conditions: Apache-2.0, a design that the open-source tools process, published in IHP's GitHub,
  and the Open Silicon MPW Program Participation Agreement; keeping the IP private costs the
  regular MPW price less 20 %.  A separate free area for non-commercial work (education, research)
  has existed in earlier runs: worth asking about.
- Samples: 40 bare dies (20 on another page) (?).  Turnaround: about 4 (or 6) months for
  SG13CMOS, 6 (or 8) for SG13G2 (?).

Packaging, for open-source designs in these runs only (200 µm thick dies, QFN with epoxy-sealed
lids; set-up 320 € per bonding diagram, which may or may not be included in these totals (?)):

| Package | Body | Pitch | Largest die | 10 pcs | 20 pcs | 30 pcs | 40 pcs |
|---|---|---|---|---|---|---|---|
| QFN 32 | 5 × 5 mm | 0.5 mm | 3 × 3 mm | 710 € | 1000 € | 1290 € | 1580 € |
| QFN 48 | 7 × 7 mm | 0.5 mm | 4.9 × 4.9 mm | 750 € | 1080 € | 1410 € | 1740 € |
| QFN 64 | 9 × 9 mm | 0.5 mm | 6.6 × 6.6 mm | 790 € | 1160 € | 1530 € | 1900 € |

(Another source also lists QFN 24 and 28.)

For `asic_soc_rv32imc` (2.0 × 2.0 mm, 20 pads):
- QFN 32 fits: the die is under 3 × 3 mm, and the 12 spare pins can take more core and I/O supply
  pads (one VDD/VSS pair is thin for the current and the bond-wire inductance), GPIOs or SPI chip
  selects.  With a packaged chip the test board needs no chip-on-board or daughter card: a QFN 32
  socket, or the chip soldered.
- 4 mm² cost about 6000 € in SG13CMOS5L (4000 € at 1000 €/mm²) against 11 200 € in SG13G2, plus
  about 1000-1300 € to package 20 chips.  This makes SG13CMOS5L the first candidate if Wally closes
  there, and die area the main cost: the pad ring takes 365 um on each side, about 60 % of a
  2.0 mm die around a 1.27 mm core.

## Next

1. The chip `asic_soc_rv32imc`:
   - minimum metal density: Metal2/Metal3 straps in the core PDN (routing with them stops at 32
     violations in the antenna repair pass); the full Chip flow ending clean (now it stops at the
     density checker), then the same in SG13CMOS5L, where the straps must avoid the Metal4 ones;
   - the chip in SG13CMOS5L (`make PDK=ihp-sg13cmos5l CONFIG=asic_soc_rv32imc`);
   - gate-level simulation of the final netlist with the cocotb test (`make chipsim` runs the RTL);
   - 40 ns for now: at 30 ns a path from the PLIC (`MExtInt` is combinational from the priority
     registers) through the trap logic to the 64-bit counters fails the slow corner by 6.8 ns
     (229 paths, all from `intPriority`); register `MExtInt`/`SExtInt` at the PLIC output (one
     cycle more of interrupt latency; an RTL change, through a PR with the interrupt tests) and
     go back to 30 ns; a test of the SPI;
   - harden the SoC as a macro, so that iterations on `chip_top` (pads, floorplan) take minutes;
   - debug access, which Wally lacks (no RISC-V Debug Module, debug mode or JTAG; the upstream
     `debug` branch holds FPGA ILA constraints, not that), before the tape-in:
     a. a monitor in the BOOTROM (`chip/boot.S`): UART commands to read and write memory and
        peripherals and to jump, and a register dump on a trap; no RTL change, a 1-2 KiB ROM;
     b. a JTAG to AHB bridge in the chip's SoC: a TAP (TCK, TMS, TDI, TDO, from the spare QFN 32
        pins) driving a second bus master, which reads and writes memory and peripherals and holds
        the core in reset even when the core or the bootloader hangs; a module outside the core,
        with a bus arbiter, tested with cocotb and an FT2232 or a Pico on the board;
     c. a trace buffer in the chip's SoC: a ring of the last N retired instructions (PC, and the
        cause on a trap; 256 x 32 bits is 1 KiB, flops or a small IHP SRAM macro), frozen by a
        trigger (trap, an address, a JTAG command, a watchdog) and read through the bridge as a
        peripheral; no extra pins.  It takes the retired instructions from outside the core, as
        the FPGA does with `src/rvvi/rvvisynth.sv` (which also packs register writes and CSRs);
   - the full RISC-V debug specification (debug mode, `dcsr`/`dpc`, Debug Module, abstract
     commands, triggers, GDB through OpenOCD) changes the core, so it goes on its own branch from
     `main` (`riscv-debug`) and through a PR with its tests, not into this flow; the standard trace
     (E-Trace or N-Trace: an encoder of compressed branch history, a trace port or a memory sink,
     and its decoder) goes there too, after the Debug Module.
2. The 64-bit core, hierarchically:
   - synthesize `syn_rv64gc` with `SYNTH_HIERARCHY_MODE: keep` (and `--keep-hierarchy` for slang)
     to measure the area and ABC time of each module; flat ABC never finished (>6 h, 20 GB);
   - harden the FPU as a macro and reuse it while its sources do not change: a Makefile rule per
     block that depends on its `.sv`, the `config.vh`, the LibreLane version and the PDK;
   - then the MDU, and caches with SRAM macros, if the measurements justify them; IFU, IEU,
     hazard, LSU and CSRs stay in the flat top (too many signals between them);
   - budget the clock period across block boundaries, and check the assembled netlist
     (gate-level simulation or equivalence), since each macro is hardened on its own;
   - with the area, size a 64-bit multicore against the shuttle area.
3. The shuttle and the board (see "IHP open-source shuttles and packaging"):
   - confirm with IHP the samples, turnaround, packaging set-up cost and any free area for
     research, and choose the run (SG13CMOS5L 14.03.2027, registration until 2027-03-01, or later);
   - shrink the die (area is the cost), and fill the QFN 32 pins: more supply pads, more GPIOs;
   - test board in KiCad for the QFN 32: separate 1.2 V core and 3.3 V I/O supplies with current
     sense, 25 MHz oscillator and an external clock input, reset, USB-UART, switches with series
     resistors on GPIO[7:0] (the bootloader reads its baud divisor there), SPI flash, test points.
4. Upstream issues to follow, and exceptions to drop when they are fixed: Magic `Cnt.c` inside the
   SRAM macros (IHP-Open-PDK #794, #1024; `check_drc.py`), the bondpad cell missing from the PDK
   (`chip/ip/`), and a stable LibreLane 3.1 to replace 3.1.0.dev4.
