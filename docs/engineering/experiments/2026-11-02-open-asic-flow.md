# Open ASIC flow: LibreLane on IHP SG13G2

Status: **feasible for `syn_rv32imc`.** With a 30 ns clock the flow runs from RTL to
a GDS with no DRC, LVS or antenna errors and positive setup and hold slack in all three
corners. Not yet done: SRAM macros, a chip-level top with a pad ring, and the slew and
fanout violations below.

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
- IHP's LibreLane template (`ihp-sg13g2-librelane-template`) has a chip top with a pad ring, SRAM
  macros with their PDN and a cocotb testbench; it adds cocotb to LibreLane's Nix shell.

## Next

1. A newer PDK with PR #863, to run Magic DRC on designs with macros.
2. A chip-level top with pads and a way to load programs (UART or SPI), from IHP's template, and
   a cocotb (gate-level) simulation of the whole `asic_*` core, whose memories the ACT tests do
   not fit.
3. Area of `syn_rv64gc` (try without Magic DRC and with a hierarchical flow), to size a
   64-bit multicore against the shuttle area.
4. Check the current IHP open shuttle rules and deadlines before sizing a design.
