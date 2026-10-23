# Buffered CPU/bus temporal contract and boundary verification

Status: **PASS** for the checks recorded below. Source:
`multicore-support:8ecb9ef1b87afdebec3f1f3e84cbd9608d265ad8` plus the
recommendation-4 working tree, identified by the source hashes below. Contract:
[core/bus interface](../interfaces/core-bus.md); decision scope:
proposed [ADR 0016](../decisions/0016-core-bus-temporal-contract.md).

## Changes and reproduction

The reusable corebus_contract checker observes accepted requests and their
actual data phase in ahbmulticore and the outer ahbmsifabric. Additional engine
assertions guard downstream wait ownership, AMO exclusion, matching read/write
address/size and rejection without downstream issue. All new monitor state is
in synthesis translate-off regions. There is no functional datapath, pipeline
stall/flush, port/configuration or single-hart-bypass latency change.

The new adapter_tb connects real ahbinterface/busfsm and EBU instances to the
serial bridge or a two-home MSI fabric. It supplements the earlier synthetic
masters and full-core programs. After setup, reproduce from the root:

```bash
source ./setup.sh
make deriv
python3 tests/multicore/ci.py --skip-deriv \
  --work-dir sim/verilator/wkdir/corebus-contract/final-ci
lint-wally
# Optional focused reproduction of just the boundary cases:
python3 tests/multicore/check_boundary.py --negative --work-dir /tmp/cvw-boundary
```

The bus CI case invokes the one-home boundary matrix and six negative cases;
mesi-banked invokes the two-home boundary matrix. Thus ordinary regression
and the Multicore workflow run these automatically through the shared CI
entrypoint. Existing unit-runner source lists now include the checker. The
default single-hart native bypass does not instantiate it.

Host: setup-selected RISCV=/home/aflores/riscv, Verilator 5.036, RISC-V GCC
15.2.0, host G++ 15.2.0 and Python 3.14.4. All directed and full-core simulation commands enable assertions.
The adapter fixture uses --output-split 0 for the same Verilator coroutine
generation limitation already recorded for the controller benches.

## Coverage criteria

- RV32gc/RV64gc, two/three harts, one/two homes and memory latency 0/3:
  16 positive adapter executions in the CI matrix.
- Delayed data through actual LSU data/strobe flops, partial writes, accepted
  metadata retained while the live address/atomic inputs change, and replies
  delivered to the real fetch buffers.
- Actual EBU simultaneous IFU/LSU arbitration during an AMO, plus a queued
  peer and an assertion that lock contention was exercised.
- Failed/successful SC, retained failure across IFU and a stalled MEM3 stage,
  downstream SC ERROR and retention across a subsequent IFU reply.
- Two-cycle local ERROR for read/store, AMO read failure followed by local
  orphan-write rejection, AMO write failure and lock recovery.
- Pre-issue flush produces no accepted address. Reset during an accepted AMO
  write cancels that pending write and lock, and clears a live LR reservation;
  a following read checks only the previously persisted RAM value.
- Six broken endpoint fixtures must exit nonzero with their specific diagnostic:
  BAD_DATA, BAD_STRB, BAD_OP, BAD_SC, BAD_AMO_ADDR and BAD_ERROR. This is a
  sensitivity check; a timeout, build error or unrelated simulator error is
  not accepted as a detected protocol violation.

The ordinary multicore CI additionally retains its seven topology lints,
28 full-core atomic/smoke runs, two translated single-hart AMO programs,
four differential peripheral comparisons, two clock/reset checks, 16 coherence
controller runs, four burst tests and common bus/peripheral/atomic units.
## Observed final verdicts

| Check | Result |
| --- | --- |
| Real adapter matrix | PASS, 16 positive executions: RV32/RV64, 2/3 harts, one/two homes, latency 0/3 |
| Negative fixtures | PASS, all six expected diagnostics observed; unrelated exits/timeouts are not accepted |
| MEM3 retention | PASS, completed LSU reports BusCommitted=1/BusStall=0 before and after the IFU reply while pipeline stall remains asserted |
| Standard lint | PASS, seven configurations, no errors or warnings |
| Explicit topology lint | PASS, seven one/two/three-hart elaborations |
| Full-core atomic/smoke | PASS, 28 executions across scalar/MSI/MESI profiles with all new assertions active |
| Existing coherence/burst matrix | PASS, 16 controller and four burst executions, plus common bus/peripheral/atomic units |
| Single-hart baseline | PASS, four differential peripheral comparisons (12,000 common accesses), two clock/reset cases and two translated AMO/PTE programs |
| Scoped pre-commit and documentation links | PASS |

All four final CI cases returned PASS and the runner exited 0. Recorded times
were 24.41 s (single-default), 38.43 s (bus), 21.22 s (MSI), and 44.66 s
(MESI/two homes) with existing build/ccache state; these are not cold CI timing
guarantees. The final aggregate and both boundary manifests were checked against
the actual final source hashes. No new functional regression was observed in
this scope; the six simulator assertion exits are intentional sensitivity tests.

## Local evidence and limitations

`sim/verilator/wkdir/corebus-contract/final-ci/` contains per-case commands, logs,
models and source/tool/configuration manifests; boundary logs and summaries
are under `bus/adapter/` and `mesi-banked/adapter/`. An earlier pilot is under
`sim/verilator/wkdir/corebus-contract/adapter/`; it predates the final fixture
and is not counted as evidence for the final working tree.
Top-level final diagnostics are `/tmp/cvw-corebus-final.log` and
`/tmp/cvw-corebus-lint.log`. Earlier runs under `ci/` and the standalone pilot
are not substituted for the final-source manifests.

Final aggregate `final-ci/results-all.json` SHA-256:
`b3510ee9c3922ef5d1ef61d7433f64f2d6b1799cfa88d30aebbc2df43699455f`.
Final top-level CI log SHA-256:
`730d2262b687a931df91c712ba87cc39c3469a93024c2633e1449e4e7a2a294d`.
Standard lint log SHA-256:
`68fca2bbfbc9ee36c815059771d4755d59198e6000ff30ed3c87db23318557a6`.

Tested sources, effective configurations, final commands/logs/manifests, ELFs,
contract/ADR snapshots and scoped pre-commit output are preserved outside
permanent docs in the ignored repository-local archive
`sim/verilator/wkdir/corebus-contract/evidence-20261021/evidence.tar.gz`, SHA-256
`4d611c3d894eb1f8439bcc3a17322553f3715db2801cda3ce19b314702712ab0`.
This survives /tmp cleanup; it is not an externally durable archive.

The earlier source-scoped results remain historical, not proof for this working
tree. No new full ACT regression, RTL Linux, remote GitHub job, formal proof,
synthesis/timing or hardware boot was run. ERROR tests validate routing and
adapter recovery; EBU still ignores HRESP for CPU exception generation. The
contract does not add rollback or cancellation of accepted work. Simulation
assertions cannot prove progress with an unresponsive slave or incomplete AMO.
All executed simulations use Verilator's two-state model. Four-state X behavior
was not simulated; the checker uses case equality for data stability so an
unchanged undefined error value or unused data lane is not itself a violation.
