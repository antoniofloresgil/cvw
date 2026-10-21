# Verification knowledge and evidence

The [test plan](../testplans/testplan.md) owns the project-wide verification
scope. Its PASS/TBD entries are project records, not results of this
documentation task. [AGENTS.md](../../AGENTS.md) supplies the normal workflow;
always check commands against the checkout's scripts.

The [2026-10-18 integration record](experiments/2026-10-18-upstream-integration.md)
contains newly executed lint and directed RTL results, plus compatibility
adaptations required by this host. Earlier historical results stay scoped to
their original branches and configurations.

The [2026-10-19 multicore integration record](experiments/2026-10-19-multicore-main-integration.md)
records revalidation after merging `main:82d0b80f7` into `f655debae`.
Use that record for the combined checkout; the original stage-3 PASS alone
does not validate the newer upstream interfaces.

The [private MSI record](experiments/2026-10-19-private-msi.md) covers the
optional private data-cache working tree based on `35cb2093b`. Its results
are separate from the earlier shared-cache Linux boot. Reproduction commands
and the write-back-aware full-core observer are documented in
[tests/multicore/README.md](../../tests/multicore/README.md).

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

## Automated multicore matrix

On the working tree based on `multicore-support:67ec3d991`, ordinary
`regression-wally` and the dedicated Multicore GitHub Actions workflow select
the same four cases in [ci.py](../../tests/multicore/ci.py). After setup:

```bash
regression-wally --multicore           # Only the bounded matrix; no ACT/Linux
python3 tests/multicore/ci.py --case msi # One case for diagnosis
```

| Case | Lint and functional scope |
| --- | --- |
| single-default | Default one-hart RV64gc lint; RV32/RV64 differential single-hart CLINT/PLIC checks against fixed upstream ancestor 4ce065926 and SMP(1); RV32i/RV64gc clock/reset with and without bus; RV64 translated AMO/PTE A/D/LR-SC with ordinary and forced-uncacheable data |
| bus | Two/three-hart wrapper lint; RV32/RV64 peripheral checks and bus wait/error/atomic-ordering units; atomic and smoke programs with 1/2/3 harts and latency 0/3 |
| msi | Two/three-hart lint, one home, MSI private I/D, forwarding and local reads/writes, 32-word banks, four-word lines; RV32/RV64 controller wait/error/coherence checks and RV64 atomic/smoke with 2/3 harts, latency 0/3 |
| mesi-banked | Two/three-hart lint, two homes, MESI private I/D, local reads/writes, four-word burst transfers, 32-word total banks; RV32/RV64 burst and banked-controller checks and RV64 atomic/smoke with 2/3 harts, latency 0/3 |

All simulations enable assertions. These are small eviction-stress profiles,
not deployment capacity changes. Explicit topology lint uses the same warning
policy as lint-wally. The ordinary standard/nightly regression adds the matrix;
special coverage/benchmark modes retain their existing selection.

The standalone runner generates derivatives once; enclosing regression passes
`--skip-deriv` after generating them before worker startup. Do not regenerate
config/deriv concurrently with simulations. Each case has separate builds,
commands and logs under `sim/verilator/wkdir/multicore-ci/`; `results-<case>.json`
or `results-all.json` records tool/source/configuration hashes and verdicts.
CI retains logs and JSON on failure and limits each job to 30 minutes.

The single-hart comparison requires Git object
`4ce065926c8096f34c77867c358f044ec1ea777e` (an ancestor of this feature branch).
CI fetches full history; shallow local checkouts must supply that object.
There is no licensed simulator, ACT generation or Linux image requirement for
the dedicated matrix. Keep long RTL Linux checks in their existing separate
procedures. Execution results and current limits are in the
[matrix record](experiments/2026-10-21-multicore-ci.md).

Recommendation 4 adds real ahbinterface/busfsm/EBU boundary fixtures to the
same per-change matrix: bus selects one home and mesi-banked selects two homes,
each with RV32/RV64, two/three harts and latency 0/3. The bus case also requires
six deliberately broken endpoints to trigger named assertions. The standalone
command runs both home counts:

```bash
python3 tests/multicore/check_boundary.py --negative --work-dir /tmp/cvw-boundary
```

The [port contract](interfaces/core-bus.md) specifies acceptance versus delayed
payload, sideband lifetime, AMO pairing/exclusion, retained SC, ERROR and abort
semantics. Assertions are active in all existing assertion-enabled buffered
bridge/fabric tests, including full-core/coherence runs. Their simulation state
is excluded from synthesis; native single-hart bypass remains unchanged. See
the [boundary execution record](experiments/2026-10-21-core-bus-contract.md).
Manual simulation source lists containing ahbmulticore/ahbmsifabric must also
include `src/ebu/corebus_contract.sv`; the maintained runners do so automatically.

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
