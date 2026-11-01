# CORE-V-Wally agent notes

## Maintainability and upstream compatibility

This repository tracks upstream CORE-V Wally. Implement extensions so they
remain understandable, verifiable, and inexpensive to maintain as upstream
evolves. Apply these rules while designing and implementing changes, not only
during final cleanup.

### Design before editing

- Before a substantial change, inspect the relevant RTL, configuration,
  verification code, and existing extension patterns.
- Briefly identify the integration points, files that must change, and how
  the existing configurations will retain their behavior.
- Prefer a cohesive implementation with clear interfaces and a small,
  justified footprint in existing upstream code.
- When a wider refactor is necessary for correctness or maintainability,
  explain why and keep it separate from the functional change.

### Keep changes focused

- Follow the naming, formatting, module structure, and coding idioms of the
  surrounding code.
- Do not reformat, rename, reorder, move, or clean up unrelated existing code.
  Avoid whitespace and alignment changes to neighboring lines.
- Keep existing module names, ports, parameters, hierarchy, and file paths
  stable unless the feature requires a change.
- Reuse existing helpers and configuration mechanisms when appropriate.
  Do not introduce generic frameworks or speculative abstractions.
- Do not copy an upstream module merely to add a feature. Prefer a shared
  implementation or a focused extension at a clear boundary.
- Do not sacrifice correctness or readability merely to minimize line count.

### RTL extension boundaries

- Put substantial new functionality in cohesive modules when it has a clear
  hardware responsibility and interface. Keep integration edits localized.
- Do not force logic into wrappers or new modules when doing so obscures
  pipeline control, duplicates state, or complicates timing.
- Use the existing elaboration-time configuration mechanism for optional
  features. Avoid scattered preprocessor conditionals and special cases.
- Where the feature is optional, preserve existing behavior when disabled
  and allow unused hardware to be eliminated during elaboration/synthesis.
- Preserve pipeline stage alignment and stall/flush/reset semantics.
  Document interface assumptions about latency, handshakes, ordering,
  arbitration, and ownership where relevant.
- Document why a non-obvious integration change is necessary. Avoid comments
  that merely repeat the RTL.

### Verification

- Select verification based on the affected behavior and configurations.
  For optional features, check both enabled and disabled configurations.
- Add or update focused tests/assertions for new behavior and relevant corner
  cases. Verify preserved behavior after any preparatory refactor.
- Consider synthesis and timing implications when changing critical paths,
  fanout, arbitration, or pipeline boundaries.
- Report the commands actually run, results, and any unverified areas.
  Do not treat a conflict-free merge or passing lint as functional proof.

### Diff and commit discipline

- Review both the task diff and the cumulative feature-branch diff against
  the appropriate upstream merge base before declaring the work complete.
  Identify the upstream reference first; do not assume its name.
- Remove accidental edits, unrelated cleanup, debug leftovers, and generated
  outputs that are not intended to be versioned. Run `git diff --check`.
- When preparing commits, keep behavior-preserving refactors separate from
  functional changes. Each commit should represent a coherent step and
  include the verification needed for that step.
- Summarize the changes to existing upstream files and explain any broad
  interface or structural changes.
- Do not merge, rebase, rewrite history, or create commits unless requested.

## Setup and build

- Run `source ./setup.sh` from the repository root before build/simulation commands. It selects `~/riscv` before `/opt/riscv`, requires `$RISCV/site-setup.sh`, and exports `$WALLY` and the `bin/` PATH. Merely exporting a custom `$RISCV` does not override this selection; see the README's toolchain configuration instructions.
- Setup can install the Git pre-commit hook via `uv run pre-commit install`. Python tooling uses `uv` (`pyproject.toml` / `uv.lock`); `wsim`, `lint-wally`, and `regression-wally` have `uv run --script` shebangs.
- Initialize dependencies with `git submodule update --init --recursive`. `addins/` contains separately versioned dependencies. `addins/riscv-arch-test` is the ACT4 checkout (upstream `act4` branch); there is no RISCOF tree or `tests.vh` suite list any more.
- Root `make --jobs` builds test inputs and derivative configurations, not a standalone RTL executable. Focused targets include `make act`, `make periph`, `make zsbl`, `make coverage`, `make testfloat`, and `make deriv`.
- `make act` builds the ACT4 tests for every configuration that has `config/<cfg>/act/test_config.yaml` into `addins/riscv-arch-test/work/cvw-<cfg>/elfs/` (set `ACTDIR` for another checkout). Changing a configuration's `act` files discards and rebuilds that configuration's ELFs. After changing `config.vh` or `config/<cfg>/act`, run `actconfig-sync --check`.

## Focused verification

Commands below assume successful setup and built inputs for the selected test.

```bash
make deriv                                  # needed for derivative configs, including lint's fdqh_rv64gc
lint-wally                                  # fast RTL check before simulation
ACT=$WALLY/addins/riscv-arch-test/work/cvw-rv64gc/elfs
wsim rv64gc $ACT/rv64i/I --sim verilator      # every ELF under a directory, one session
wsim rv64gc path/to/test.elf --sim verilator  # one ELF
wsim rv64gc --elf path/to/program --sim verilator # ELF without .elf suffix
regression-wally                            # multi-config regression; default simulator is Verilator
uv run pre-commit run --files path/to/changed/file
```

- `wsim` defaults to **Questa**, unlike regression; specify `--sim verilator` for open-source simulation. `--vcd` produces a waveform; `--args` passes simulator plusargs, while `--params` overrides top-level parameters.
- Questa is required for `--gui`, `--ccov`, `--fcov` (compiles in the ACT covergroups) and `--tb testbench_fp`. `--lockstep` uses ImperasDV with Questa/VCS and accepts a single ELF or `buildroot`, not an ordinary suite.
- Tests are ELF files named by path or directory; regression's configuration and test combinations live in `bin/regression-wally`, whose nightly modes may still name removed `tests.vh` suites (see the comment there). Build products and logs are under `sim/<simulator>/wkdir/` and `sim/<simulator>/logs/`.
- Run one `wsim` at a time per configuration and simulator: concurrent runs share `sim/<simulator>/wkdir/` and race while compiling. Parallelize across configurations instead.
- `regression-wally --nightly` expands coverage substantially, including Linux boot (many hours) and tests requiring commercial tools. `lint-wally --nightly` includes generated derivative configs.
- CI's general lint check is `pre-commit run --all-files --show-diff-on-failure`; hooks exclude `addins/` and Ruff runs with `--fix`. CI checks Ruff compatibility for both Python 3.9 and 3.13.

## RTL and configuration changes

- The SoC/core entrypoints are `src/wally/wallypipelinedsoc.sv` and `src/wally/wallypipelinedcore.sv`. Simulation uses `testbench/testbench.sv`; RTL lint elaborates `testbench/wallywrapper.sv` instead.
- Configuration is elaboration-time data: `config/<target>/config.vh` supplies localparams, `config/shared/config-shared.vh` derives values, and `config/shared/parameter-defs.vh` populates the `cvw_t` struct defined in `src/cvw.sv`. Modules receive it as parameter `P`; a new configuration field must be wired through these layers.
- Edit base configurations or `config/derivlist.txt`, then run `make deriv`. `derivgen.pl` deletes and recreates all of `config/deriv/`, so direct edits there are lost.
- Signal suffixes F/D/E/M/W denote Fetch/Decode/Execute/Memory/Writeback. Stall/flush coordination lives in `src/hazard/hazard.sv`; preserve stage alignment when changing datapaths.
- `.editorconfig` specifies two-space indentation for `src/**/*.sv` and four spaces otherwise. Ruff targets Python 3.9; pre-commit forbids tabs except in Makefiles and its listed exceptions.
- `CLAUDE.md` has a broader architecture overview; verify command details against `bin/` scripts (notably the `--fcov` limitation above). Verification scope is documented in `docs/testplans/testplan.md`.

## Hardware, FPGA and bring-up method

These rules come from the `claude-for-hardware` plugin, kept to what this repository's experience supports. The plugin's prose style (ASD-STE100, no em dashes) does not apply; follow the surrounding documentation.

- **Measure, then change one thing.** For area or Fmax work, read the critical-path report and per-module resource counts first, change one structure, and re-measure. Stop optimizing a path once it leaves the critical path. In the open flow the Linux configuration's gains came from specific structures (linear `popcnt`/`lzc` chains rewritten as trees: 5.7 to 14.9 MHz), not from general effort.
- **Judge fit and timing after placement.** Yosys `stat` counts are pre-pack. Use nextpnr's `Device utilisation` and the last `Max frequency for clock` line; an earlier "Max frequency" line is the pre-route estimate. A build whose HCLK line says FAIL at the target clock does not meet timing, even if `--timing-allow-fail` produced a bitstream.
- **Bound and background long commands.** Wrap synthesis and routing in `timeout` or run them in the background and wait for the completion notice; do not poll or sleep. Before killing a slow stage, check whether it is converging (placer cost falling, router overuse trending to zero). ABC9's final `&verify` hangs on RV64GC for hours, so the open flow sets `abc9.verify 0`.
- **Race experiments, within memory.** Independent placer/router seeds or knobs can run concurrently (nextpnr is mostly single-threaded; Yosys on RV64GC peaks near 2.7 GB, and a nextpnr run was about 1.2 GB resident while placing). Check free memory first. Keep each experiment in its own directory with its log, and record the baseline it is compared with.
- **Pin the place-and-route engine.** The open flow requires openXC7 nextpnr-xilinx 0.9.8 with `bin/installation/nextpnr-xilinx-lutram-clkinv.patch`; the earlier gatecat revision produced bitstreams whose DDR3 reads failed. A newer engine is not safer. The open flow has no static timing for clock skew, so an unrelated logic change that breaks DDR3 calibration points at placement, not at the added logic.
- **Separate simulation proof from hardware proof.** Verilator/ACT results do not prove a bitstream, and a board result on one configuration does not transfer to another. State which was run. If hardware misbehaves while simulation passes, partition the problem (compiled simulation of the same RTL, then one layer at a time on the board: clock and PLL lock, reset, memory, core) instead of theorizing.
- **Bring-up hygiene.** Confirm the bitstream actually loaded before debugging the design. Every clock-derived constant (PLL ratio, UART divisor, timebase, device-tree clock properties) must match the clock the build achieved; the Linux configuration runs at `SYSTEMCLOCK` 12.5 MHz and its ZSBL rewrites the device-tree clocks to it. The UART drops output for a short time after reconfiguration, and a stale serial reader can split the stream.
- **Do not mask failures.** Diagnostic switches (`--timing-allow-fail`, skipped checks) are for finding a cause. Fix the cause, and report a skipped or failing check as such.
- **Use the plugin's reviewers.** Before declaring an RTL change complete, run the `claude-for-hardware:rtl-reviewer` agent on the diff in addition to the checks above. Use `claude-for-hardware:bringup-debugger` when a design builds but is silent or hangs on hardware, and the `fpga-fit` and `rtl-area-timing` skills for fit and Fmax loops.

## Persistent Engineering Knowledge

- Read [docs/engineering/README.md](docs/engineering/README.md), then [current-work.md](docs/engineering/current-work.md); load only the architectural, verification or implementation records relevant to the task. Existing READMEs, CLAUDE.md and the test plan remain the detailed references.
- Record significant choices as scoped ADRs in `docs/engineering/decisions/` with explicit proposed/accepted/superseded/rejected status. Keep reproducible experiment summaries in `docs/engineering/experiments/`; identify revision, configuration, tools, observed verdict, artifact paths/hashes and missing evidence. Keep raw logs and generated artifacts outside permanent docs.
- After substantial changes, update only the affected architecture/interface notes, ADR, verification procedure or experimental record, and refresh `current-work.md` when objectives, branches, results or blockers change. Distinguish verified facts, hypotheses, plans and unexecuted/blocked checks; never promote a proposal or experiment automatically into an accepted decision.
- Record optimization and bring-up experiments under `docs/engineering/experiments/` with the fields listed in [implementation.md](docs/engineering/implementation.md) (source revision, configuration, tools and seed, stage reached, comparable baseline, unexecuted checks).
- Check the index's revision-specific verification notes before reusing remembered commands: scripts and RTL in the checked-out revision determine current behavior. Preserve branch boundaries; a feature-branch result is not evidence for main or for FPGA hardware. Do not turn these notes into a session transcript or update every document after every task.
