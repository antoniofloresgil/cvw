# Open ASIC flow (LibreLane, IHP SG13G2 and SG13CMOS5L)

Takes a Wally configuration from RTL to a checked GDS with open tools only: Yosys
(with the slang frontend), OpenROAD, Magic, KLayout and Netgen, driven by
[LibreLane](https://github.com/librelane/librelane) on the IHP open PDK. No Wally RTL is modified.

```bash
nix develop github:librelane/librelane/3.1.0.dev4 --accept-flake-config   # once, to check Nix works
make CONFIG=syn_rv32imc                  # synthesis to GDS, DRC, LVS (40 ns clock)
make CONFIG=syn_rv32imc CLOCK_PERIOD=30  # another clock period
make synth CONFIG=syn_rv64gc             # synthesis only
make CONFIG=sramtest                     # one IHP SRAM macro (sramtest/), then check_drc.py
make CONFIG=asic_rv32imc                 # syn_rv32imc with a 4 KiB DTIM in an IHP SRAM macro
make CONFIG=asic_soc_rv32imc             # a chip: the SoC in a pad ring (chip/), Chip flow
make chipsim                             # cocotb test of that chip (RTL): boots a program over the UART
make PDK=ihp-sg13cmos5l CONFIG=asic_rv32imc   # the same in SG13CMOS5L, in work/asic_rv32imc-sg13cmos5l
```

Requirements: [Nix](https://nixos.org/download) (tested with Determinate Nix 3.24.1, which is Nix 2.35.3) with flakes and the FOSSi cache
(`extra-substituters = https://nix-cache.fossi-foundation.org` and its key, in
`/etc/nix/nix.custom.conf`; LibreLane's documentation gives both). LibreLane is not
vendored: `LIBRELANE` in the Makefile pins a release. `PDK_VERSION` is the IHP PDK that this
release pins; `make pdk` downloads it with ciel into `~/.ciel` (both processes, without enabling
it), and the flow reads it from there. `make chipsim` needs cocotb and Verilator from
[oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build) (`OSS_CAD`, default `~/riscv/oss-cad-suite`).

`gen_config.py` writes `work/<CONFIG>/config.json` and a wrapper module that binds
`wallypipelinedcore`'s parameter `P` to the configuration's `config.vh`. Results are
in `work/<CONFIG>/runs/RUN_*/`: `final/` holds the GDS, netlists, SPEF and
`metrics.json`; each numbered step directory has its log and reports.

Configurations:

- `syn_*`: the core alone, memories in flops.
- `asic_*` (`config/derivlist.txt`): RAMs of a shape that an IHP SRAM macro implements go in the
  macro (`sram/ram1p1rwbe.sv`); `gen_config.py` copies Wally's `ram1p1rwbe` as `ram1p1rwbe_generic`
  for the other shapes. `make sramsim` checks the adapter, with the macro's behavioral model, against
  Wally's RAM under random stimulus.
- `asic_soc_*`: chips. `chip/chip_top.sv` puts `wallypipelinedsoc` inside a ring of IHP pads (clock,
  reset, UART, SPI, 8 GPIOs and 4 power pads), after IHP's
  [LibreLane template](https://github.com/IHP-GmbH/ihp-sg13-librelane-template); the bondpad comes
  from the template (`chip/ip/`), since the PDKs have none. The BOOTROM holds `chip/boot.S`
  (built into `chip/boot.mem`): it reads a baud divisor from GPIO[7:0], sends `W` on the UART,
  receives a 4-byte length and the program into the 4 KiB RAM at 0x80000000 (an SRAM macro), sends
  its 8-bit sum and jumps to it. `chip/test/test_chip.py` loads `hello.S` that way.

Notes:

- The clock is 40 ns for every design. With LibreLane 3.1 (Yosys 0.69) `asic_rv32imc` misses 30 ns
  by 6.8 ns in the slow corner, and the chip has a path from the PLIC through the trap logic to
  the counters as long. Synthesis uses `SYNTH_STRATEGY` `AREA 0` with `SYNTH_ARITH_TREE` and
  `SYNTH_MUL_BOOTH` off: 3.1's defaults (`DELAY 4`, both on) close 30 ns, but with 50 % more area
  and power.
- The timing checkers fail the flow only for the corners their wildcards match: by default
  `TIMING_VIOLATION_CORNERS` is `*typ*` (setup) and the max slew and max cap checkers match
  none. `gen_config.py` sets `TIMING_VIOLATION_CORNERS` to `["*"]`; read
  `design__max_slew_violation__count` per corner in `final/metrics.json`.
- Magic DRC takes 1.5-3 h, with no output until it ends; the KLayout DRC is the reference for IHP.
- DRC of designs with SRAM macros: KLayout DRC is clean and stays fatal. Magic still reports
  `Cnt.c` and `Cnt.c SRAM exception` inside the macros (IHP-Open-PDK #794, #1024), so these designs
  set `ERROR_ON_MAGIC_DRC` to false and `make` runs `check_drc.py`, which waives only those rules
  inside the macros' bounding boxes. In a chip Magic also reports overlaps between the subcells of
  the pad ring (`Can't overlap those layers`, `This layer can't abut or partially overlap between
  subcells`); KLayout DRC, the PDK's official deck, finds no error there, and `check_drc.py` reports
  them outside the core area as warnings when KLayout DRC is clean. Any other Magic violation fails.
- `sram/pdn_cfg.tcl` is LibreLane's with one more connection, Metal4 (the macro's power pins) to
  the horizontal straps, in SG13G2 only (in SG13CMOS5L the vertical straps are on Metal4).
- The chip does not yet meet IHP's minimum metal density (`M2Fil.h`, `M3Fil.h`: 25 % of Metal2
  and Metal3 in every 800 x 800 um window, a precheck rule): routed Metal2 leaves gaps too narrow for
  fill in the core. The chips use IHP's Magic filler (`KLayout.Filler: Magic.Filler`), which leaves 5
  windows short (the KLayout filler 15), the worst at 20 %, and adds no DRC error. Planned:
  Metal2/Metal3 straps in the core power grid.
- `chip/chip_top.sdc` defines the clock on the clock pad's output, as IHP's template does, and sets
  the clock activity of that pin for power: OpenSTA gives a clock on an internal pin none, and the
  chip's power read 1.2 mW instead of 21 mW.
- `PDK=ihp-sg13cmos5l` uses the CMOS-only process with 5 metals (Metal1-4, TopMetal1): the same
  SRAM macros and pads under `sg13cmos5l_` names; `chip_top.sv` picks the pads with `SG13CMOS5L`.
- Flat ABC on `syn_rv64gc` did not finish in over 6 h; the 64-bit core needs a hierarchical flow.
