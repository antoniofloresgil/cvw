# Open ASIC flow (LibreLane, IHP SG13G2)

Takes a Wally configuration from RTL to a checked GDS with open tools only: Yosys
(with the slang frontend), OpenROAD, Magic, KLayout and Netgen, driven by
[LibreLane](https://github.com/librelane/librelane) on the IHP SG13G2 open PDK.
No Wally RTL is modified.

```bash
nix develop github:librelane/librelane/3.0.17 --accept-flake-config   # once, to check Nix works
make CONFIG=syn_rv32imc                  # synthesis to GDS, DRC, LVS (30 ns clock)
make CONFIG=syn_rv32imc CLOCK_PERIOD=20  # 20 ns clock: fails setup in the slow corner
make synth CONFIG=syn_rv64gc             # synthesis only
make CONFIG=sramtest                     # one IHP SRAM macro (sramtest/), then check_drc.py
make CONFIG=asic_rv32imc                 # syn_rv32imc with a 4 KiB DTIM in an IHP SRAM macro
```

Requirements: [Nix](https://nixos.org/download) (tested with Determinate Nix 3.24.1, which is Nix 2.35.3) with flakes and the FOSSi cache
(`extra-substituters = https://nix-cache.fossi-foundation.org` and its key, in
`/etc/nix/nix.custom.conf`; LibreLane's documentation gives both). LibreLane is not
vendored: `LIBRELANE` in the Makefile pins a release, and that release pins the tools
and the PDK version (downloaded by ciel into `~/.ciel`).

`gen_config.py` writes `work/<CONFIG>/config.json` and a wrapper module that binds
`wallypipelinedcore`'s parameter `P` to the configuration's `config.vh`. Results are
in `work/<CONFIG>/runs/RUN_*/`: `final/` holds the GDS, netlists, SPEF and
`metrics.json`; each numbered step directory has its log and reports.

Notes:

- The timing checkers fail the flow only for the corners their wildcards match: by default
  `TIMING_VIOLATION_CORNERS` is `*typ*` (setup) and the max slew and max cap checkers match
  none, so a violation in another corner is only a warning ("... violations found in the
  following corners") followed by "No ... violations found". Read `timing__setup__ws` and
  `design__max_slew_violation__count` per corner in `final/metrics.json`, or set
  `"TIMING_VIOLATION_CORNERS": ["*"]` and `"MAX_SLEW_VIOLATION_CORNERS": ["*"]` to make them fatal.
- Magic DRC takes about 1.5 h on `syn_rv32imc`, with no output until it ends; the
  KLayout DRC is the reference for IHP.
- Flat ABC on `syn_rv64gc` takes over 2 h and several GB.
- `sramtest/` is a test design around one `RM_IHPSG13_1P_1024x32_c2_bm_bist` macro, with its
  own `config.json`. The PDK's Verilog model of the macro needs a module the PDK does not ship,
  so synthesis reads a black box (`*_bb.v`); `pdn_cfg.tcl` is LibreLane's with one more
  connection, Metal4 (the macro's power pins) to the horizontal straps.
- The full KLayout deck reports `Cnt.c.digibnd`, `Sdiod.d` and `Sdiod.e` violations inside the
  IHP SRAM macros themselves ([IHP-Open-PDK #793](https://github.com/IHP-GmbH/IHP-Open-PDK/issues/793)).
  A design with macros sets `ERROR_ON_KLAYOUT_DRC` to false and `make` then runs
  `check_drc.py`, which fails on any other violation of the full deck and on any violation of
  IHP's foundry precheck rule set. Drop the exception when IHP fixes the deck or the macros.
  Magic DRC is off for these designs: it reports millions of violations inside the macros, because
  the SRAM rule exceptions (IHP-Open-PDK PR #863, with `read_sram_gds.tcl`) came after the PDK
  version that LibreLane 3.0.17 pins.
- `make sramsim` checks `sram/ram1p1rwbe.sv`, simulated with the macro's behavioral model from the
  PDK, against Wally's RAM under random stimulus. `asic_*` configurations (`config/derivlist.txt`)
  use it: `gen_config.py` copies Wally's `ram1p1rwbe` as `ram1p1rwbe_generic` and adds the macro.
- Not yet done: a chip-level top with a pad ring, and simulation of a whole `asic_*` core with
  the macro (the ACT tests do not fit its 512 B IROM and 4 KiB DTIM).
