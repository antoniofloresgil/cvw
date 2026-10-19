# CORE-V-Wally agent notes

## Setup and build

- Run `source ./setup.sh` from the repository root before build/simulation commands. It selects `~/riscv` before `/opt/riscv`, requires `$RISCV/site-setup.sh`, and exports `$WALLY` and the `bin/` PATH. Merely exporting a custom `$RISCV` does not override this selection; see the README's toolchain configuration instructions.
- Setup can install the Git pre-commit hook via `uv run pre-commit install`. Python tooling uses `uv` (`pyproject.toml` / `uv.lock`); `wsim`, `lint-wally`, and `regression-wally` have `uv run --script` shebangs.
- Initialize dependencies with `git submodule update --init --recursive`. `addins/` contains separately versioned dependencies, including two distinct arch-test trees.
- Root `make --jobs` builds test inputs and derivative configurations, not a standalone RTL executable. Focused targets include `make riscof`, `make coverage`, `make testfloat`, and `make deriv`.
- `make act` builds the newer `addins/riscv-arch-test-cvw` tests. The `arch64i`/`arch32i` suites in `testbench/tests.vh` instead use RISCOF outputs from `addins/riscv-arch-test`; build those with `make riscof`. For just RV64 RISCOF inputs, use `make -C tests/riscof arch64` or `make -C tests/riscof wally64` for Wally-specific tests.

## Focused verification

Commands below assume successful setup and built inputs for the selected test.

```bash
make deriv                                  # needed for derivative configs, including lint's fdqh_rv64gc
lint-wally                                  # fast RTL check before simulation
wsim rv64gc arch64i --sim verilator           # one suite
wsim rv32i arch32i --sim verilator            # RV32 integer suite
wsim rv64gc path/to/test.elf --sim verilator  # one ELF
wsim rv64gc --elf path/to/program --sim verilator # ELF without .elf suffix
regression-wally                            # multi-config regression; default simulator is Verilator
uv run pre-commit run --files path/to/changed/file
```

- `wsim` defaults to **Questa**, unlike regression; specify `--sim verilator` for open-source simulation. `--vcd` produces a waveform; `--args` passes simulator plusargs, while `--params` overrides top-level parameters.
- Questa is required for `--gui`, `--ccov`, and `--tb testbench_fp`. `--lockstep` uses ImperasDV with Questa/VCS and accepts a single ELF or `buildroot`, not an ordinary suite. `wsim --fcov` currently does nothing.
- Suite names and vector paths live in `testbench/tests.vh`; regression's config/suite combinations live in `bin/regression-wally`. Build products and logs are under `sim/<simulator>/wkdir/` and `sim/<simulator>/logs/`.
- `regression-wally --nightly` expands coverage substantially, including Linux boot (many hours) and tests requiring commercial tools. `lint-wally --nightly` includes generated derivative configs.
- CI's general lint check is `pre-commit run --all-files --show-diff-on-failure`; hooks exclude `addins/` and Ruff runs with `--fix`. CI checks Ruff compatibility for both Python 3.9 and 3.13.

## RTL and configuration changes

- The SoC/core entrypoints are `src/wally/wallypipelinedsoc.sv` and `src/wally/wallypipelinedcore.sv`. Simulation uses `testbench/testbench.sv`; RTL lint elaborates `testbench/wallywrapper.sv` instead.
- Configuration is elaboration-time data: `config/<target>/config.vh` supplies localparams, `config/shared/config-shared.vh` derives values, and `config/shared/parameter-defs.vh` populates the `cvw_t` struct defined in `src/cvw.sv`. Modules receive it as parameter `P`; a new configuration field must be wired through these layers.
- Edit base configurations or `config/derivlist.txt`, then run `make deriv`. `derivgen.pl` deletes and recreates all of `config/deriv/`, so direct edits there are lost.
- Signal suffixes F/D/E/M/W denote Fetch/Decode/Execute/Memory/Writeback. Stall/flush coordination lives in `src/hazard/hazard.sv`; preserve stage alignment when changing datapaths.
- `.editorconfig` specifies two-space indentation for `src/**/*.sv` and four spaces otherwise. Ruff targets Python 3.9; pre-commit forbids tabs except in Makefiles and its listed exceptions.
- `CLAUDE.md` has a broader architecture overview; verify command details against `bin/` scripts (notably the `--fcov` limitation above). Verification scope is documented in `docs/testplans/testplan.md`.

## Persistent Engineering Knowledge

- Read [docs/engineering/README.md](docs/engineering/README.md), then [current-work.md](docs/engineering/current-work.md); load only the architectural, verification or implementation records relevant to the task. Existing READMEs, CLAUDE.md and the test plan remain the detailed references.
- Record significant choices as scoped ADRs in `docs/engineering/decisions/` with explicit proposed/accepted/superseded/rejected status. Keep reproducible experiment summaries in `docs/engineering/experiments/`; identify revision, configuration, tools, observed verdict, artifact paths/hashes and missing evidence. Keep raw logs and generated artifacts outside permanent docs.
- After substantial changes, update only the affected architecture/interface notes, ADR, verification procedure or experimental record, and refresh `current-work.md` when objectives, branches, results or blockers change. Distinguish verified facts, hypotheses, plans and unexecuted/blocked checks; never promote a proposal or experiment automatically into an accepted decision.
- Check the index's revision-specific verification notes before reusing remembered commands: scripts and RTL in the checked-out revision determine current behavior. Preserve branch boundaries; a feature-branch result is not evidence for main or for FPGA hardware. Do not turn these notes into a session transcript or update every document after every task.
