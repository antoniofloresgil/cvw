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
- Not yet done: SRAM macros (memories are flops), a chip-level top with a pad ring,
  and timing closure in the slow corner.
