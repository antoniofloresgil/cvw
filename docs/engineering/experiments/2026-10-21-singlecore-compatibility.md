# Single-hart compatibility and multi-hart peripheral isolation

Status: **PASS** for the checks below. Branch: `multicore-support`, working tree
on `67ec3d991201f0bb2d36a0420c26b67223b8ae49`. Upstream comparison source:
`main:4ce065926c8096f34c77867c358f044ec1ea777e`. The implementation follows
proposed [ADR 0014](../decisions/0014-single-hart-peripheral-isolation.md),
addressing recommendation 2 of the maintenance review. No merge into main.

## Question and changes

Can single-hart peripheral behavior retain upstream structure while isolating
multi-hart extensions and making generic corrections independently testable?

Single-hart CLINT/PLIC now use upstream-shaped modules, with only the scoped
strobe/address/reset/range corrections described in ADR 0014. Uncore selects
the extracted multi-hart modules for NCORES>1. Clock/reset outputs regain the
upstream no-bus behavior. The cached LSU bus atomic flag now follows LSUAtomicM
when the page-table walker owns the request.

## Reproduction

Host tools: Verilator 5.036 (2025-04-27), riscv64-unknown-elf GCC 15.2.0,
RISCV=/home/aflores/riscv selected by setup.sh. From the repository root:

```bash
source ./setup.sh
make deriv
lint-wally
python3 tests/multicore/check_singlecore.py --upstream-ref 4ce065926 \
  --work-dir /tmp/cvw-singlecore-recovery --atomic-walker
python3 tests/multicore/run.py --suite atomic --cores 1 2 3 --latency 0 3 \
  --work-dir /tmp/cvw-singlecore-multicore
```

Scoped pre-commit also passed for changed/new source files. The runner records
the immutable upstream reference, source hashes, Verilator version, commands,
logs and results. It removes any old results.json before execution so a failed
rerun cannot leave a previous aggregate PASS.

## Observed verdicts

| Check | Result and scope |
| --- | --- |
| Standard RTL lint | PASS, seven configurations, no errors or warnings |
| Differential peripherals | PASS, RV32gc/RV64gc with 14/63 sources; 3,000 deterministic common transactions per case, both APB phases/idle outputs, M/S UART routing/claim/completion |
| Intentional corrections | PASS, MSIP zero/nonzero byte strobes, PLIC upper-address read/write aliases, source-zero/unimplemented priority reads and absent pending bank |
| Corrected single-hart vs SMP(1) | PASS over all exercised peripheral transactions, including intentional upstream differences |
| SoC clock/reset | PASS, RV32i/RV64gc, bus enabled/disabled, reset assertion and release, both clock edges |
| Translated AMO | PASS, RV64gc; AMO old/new data, LR/SC success/data and exact PTE A/D update checked; strict unexpected-trap handler enabled |
| Walker ownership | PASS, 10 observed cycles with SelHPTW and CPU AtomicM asserted, selected LSUAtomicM and cached bus BusAtomic deasserted |
| Negative mutation | PASS as a sensitivity check: reverting only cached BusAtomic to AtomicM in a temporary LSU copy triggers `PTE request tagged as AMO in cached LSU` |
| Multi-hart peripherals | PASS, RV32/RV64 byte lanes, strobes, timers and all six contexts |
| Bus/controller | PASS, round-robin/back-to-back/waits/ERROR routing plus LR/SC invalidation/consumption/lanes/stale queued SC and AMO exclusion/error/reset recovery |
| Full-core atomic and smoke | PASS, each with 1/2/3 harts and latency 0/3; 12 program executions |

The walker test forces data accesses uncacheable in an otherwise ordinary
RV64gc profile. Thus it exercises the changed cached-LSU bus adapter and real
translation/PTE updates, rather than relying on a cached RAM hit. The negative
mutation uses the recorded cached build command with only the LSU input and
output directory replaced; the repository RTL remains corrected.

## Failed trial and evidence limits

An initial additional cacheless/virtual-memory profile stopped at the official
configuration assertion `Virtual memory needs dcache`. This was an invalid
test profile, not a functional verdict on the LSU fix. That variant was removed
from the runner; the configuration assertion remains enabled. Its local
diagnostic is `/tmp/cvw-singlecore-recovery/atomic-walker/cacheless-run.log`.
There is no translated cacheless PASS claim. Cacheless AMO/LR/SC remains covered
by the supported multicore_atomic full-core matrix without virtual memory.

These directed checks are not exhaustive peripheral equivalence, formal
verification, or coverage of arbitrary source/hart counts. The corrections
intentionally differ from upstream on the listed accesses. No new private-cache
MSI/MESI, Linux SMP, synthesis, timing or FPGA boot was run for this change;
earlier results retain their own revision scope.

## Local artifacts

Raw logs/models are external to permanent documentation:

- `/tmp/cvw-singlecore-recovery/`: commands, peripheral/clock logs, source-hash
  manifest `results.json`, ELF and cached model/run logs under `atomic-walker/`.
- `/tmp/cvw-singlecore-recovery/atomic-walker/mutation/`: deliberately broken
  LSU copy, build command, model and expected-failure run log.
- `/tmp/cvw-singlecore-multicore/` and `/tmp/cvw-singlecore-multicore.log`:
  controller builds and full-core matrix.
- `/tmp/cvw-singlecore-lint.log`: seven-config lint, SHA-256
  `68fca2bbfbc9ee36c815059771d4755d59198e6000ff30ed3c87db23318557a6`.
- `/tmp/cvw-singlecore-multicore.log`: SHA-256
  `ed68cfdea1de012ca328c57b72f792b54b93f817befb84571736fe57f2bee01b`.
- `/tmp/cvw-singlecore-recovery/results.json`: SHA-256
  `ecd42a62c473029be01ca147ba2a5d765332aec1a708110ec9565ebe73ae6d08`.
- Preserved logs, commands, ELF, tested changed/new source files, source hashes
  and tracked diff: repository-local ignored archive
  `sim/verilator/logs/singlecore-compatibility-20261021/evidence.tar.gz`, SHA-256
  `3af2f667a714361ad57743386b23c460b685a233d918e035f14be3a33bd725a2`.

These are local locators, not a durable external archive; the repository-local
copy survives removal of /tmp. Source hashes in the
manifest identify the tested working tree independently of future commits.
