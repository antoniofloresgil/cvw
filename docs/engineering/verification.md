# Verification knowledge and evidence

The [test plan](../testplans/testplan.md) owns the project-wide verification
scope. Its PASS/TBD entries are project records, not results of this
documentation task. [AGENTS.md](../../AGENTS.md) supplies the normal workflow;
always check commands against the checkout's scripts.

The [2026-10-18 integration record](experiments/2026-10-18-upstream-integration.md)
contains newly executed lint and directed RTL results, plus compatibility
adaptations required by this host. Earlier historical results stay scoped to
their original branches and configurations.

## Revision-specific command compatibility

At `main:3585ff04e`, inspection of [bin/wsim](../../bin/wsim),
[bin/regression-wally](../../bin/regression-wally) and
[testbench.sv](../../testbench/testbench.sv) confirms:

- `wsim` accepts ELF paths/directories and special modes. Legacy `arch64i`
  suite-name examples in the preserved AGENTS notes refer to an earlier
  interface. Use the current README/CLAUDE examples and actual ACT output paths.
- `--fcov` is implemented and requires Questa; the older AGENTS statement
  that it does nothing is stale for this revision. Code coverage also requires
  Questa; lockstep requires Questa/VCS and the configured reference tools.
- `wsim` defaults to Questa; ordinary regression defaults to Verilator.
  Open-source RTL simulation and functional emulation do not establish the
  same coverage or instruction-by-instruction checking as lockstep.

Example commands for this revision, after successful setup and built inputs:

```bash
source ./setup.sh
make act
wsim rv64gc "$WALLY/addins/riscv-arch-test/work/cvw-rv64gc/elfs/rv64i/I" --sim verilator
wsim rv64gc --elf /path/to/program --sim verilator
regression-wally
```

These are inspected procedures, **not tests executed for this task**. ACT
configuration ownership is explained in CLAUDE.md and `config/<cfg>/act/`.
Do not initialize/update submodules just to read these notes. The two existing
untracked addins directories are not evidence of which test generation was used.

## Result vocabulary and preservation

| State | Required interpretation |
| --- | --- |
| PASS | Named criterion actually observed; record revision, configuration, command, tools and evidence |
| FAIL | Observed mismatch/error/timeout; distinguish a recovered report from locally inspected raw evidence |
| NOT RUN | No execution; includes suggested commands |
| INCOMPLETE | Execution started but stopped without a verdict; neither PASS nor FAIL |
| BLOCKED | Execution/retest needs a stated missing prerequisite; never count it as PASS |

For significant runs, commit a compact result record under `experiments/`:
source commit plus dirty-tree/source hashes if applicable, parameters and
effective configuration, compiler/simulator versions, commands, verdict/exit
status, coverage limits and artifact identifiers. Preserve failed experiments
when they explain a decision; do not relabel cancelled runs as failures.

Raw logs, binaries, waveforms and manifests belong in ignored simulator output
or external storage. Record paths and hashes; local absolute paths are useful
locators, not durable archives. Before cleaning the host, export important
evidence to durable storage and update its locator. If logs disappear, retain
the summary as historical evidence and explicitly mark the raw evidence absent.

The [Linux SMP record](experiments/2026-10-18-linux-smp.md) links an executed
test and preserved evidence. QEMU PASS validates that software/platform model,
not Wally RTL. A simulation PASS establishes neither FPGA DDR calibration nor
routed timing closure. For bus errors, `ebu.sv` currently labels `HRESP` as
ignored: bridge recovery tests alone do not establish CPU access exceptions.
