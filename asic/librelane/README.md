# Open ASIC flow (LibreLane, IHP SG13G2)

Takes a Wally configuration from RTL to a checked GDS with open tools only: Yosys
(with the slang frontend), OpenROAD, Magic, KLayout and Netgen, driven by
[LibreLane](https://github.com/librelane/librelane) on the IHP SG13G2 open PDK.
No Wally RTL is modified.

```bash
nix develop github:librelane/librelane/3.0.17 --accept-flake-config   # once, to check Nix works
make CONFIG=syn_rv32imc                  # synthesis to GDS, DRC, LVS
make CONFIG=syn_rv32imc CLOCK_PERIOD=30  # same, 30 ns clock
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

- `ERROR_ON_SYNTH_CHECKS` is off because `csrm.sv` leaves two PMP array entries
  undriven when `PMP_ENTRIES = 0`. They are unused; the post-synthesis check is clean.
- The Setup and Max Slew checkers print the corners that fail and then still report
  "No ... violations found", and the flow continues. Read `timing__setup__ws` and
  `design__max_slew_violation__count` in `final/metrics.json` per corner.
- Magic DRC takes about 1.5 h on `syn_rv32imc`, with no output until it ends; the
  KLayout DRC is the reference for IHP.
- Flat ABC on `syn_rv64gc` takes over 2 h and several GB.
- Not yet done: SRAM macros (memories are flops), a chip-level top with a pad ring,
  and timing closure in the slow corner.
