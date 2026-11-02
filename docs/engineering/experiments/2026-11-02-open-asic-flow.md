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

| | 20 ns clock | 30 ns clock |
|---|---|---|
| Magic DRC | 0 errors | 0 errors |
| KLayout DRC | 0 errors | 0 errors |
| LVS (Netgen) | 0 differences | 0 differences |
| Antenna violations | 0 | 0 |
| Global route / DRT errors | 0 | 0 |
| Setup slack, slow (1.08 V, 125 C) | **-6.66 ns** | +1.34 ns |
| Setup slack, typical (1.20 V, 25 C) | +1.99 ns | +5.09 ns |
| Setup slack, fast (1.32 V, -40 C) | +3.41 ns | +6.49 ns |
| Hold slack, worst corner | +0.12 ns | +0.10 ns |
| Max slew violations, slow corner | 99 | 111 |
| Max fanout violations (each corner) | 776 | 775 |
| Power (no activity data) | 44 mW | 29 mW |

Common to both: die 2.04 mm^2 (1418.8 x 1437.5 um), 82.9k standard cells occupying
1.25 mm^2, utilization 63 %, 9390 flip-flops, 0 power-grid violations. The GDS is 107 MB.
Wall time on a 30 GB workstation: about 4 h with Magic DRC (1 h 37 min of it) and KLayout
DRC (13 min).

With 20 ns the design meets timing in the typical and fast corners only; the slow corner
supports roughly a 27 ns period, so 30 ns is the first round value that closes it.

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
  stay at 0; Magic DRC was not run in that experiment. The 775 fanout violations are 98 %
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

## Next

1. Re-run the full flow (with Magic DRC) with the larger slew margins and make the checkers fatal in every corner.
2. `asic_*` configurations that use IHP SRAM macros, then a chip-level top with pads and a
   way to load programs (UART or SPI).
3. Area of `syn_rv64gc` (try without Magic DRC and with a hierarchical flow), to size a
   64-bit multicore against the shuttle area.
4. Check the current IHP open shuttle rules and deadlines before sizing a design.
