# Private MSI data-cache prototype

Date: 2026-10-19. **PASS for the checks below** on the working tree based on
`multicore-support:35cb2093bc4af2b0549fc529879b6748006fee9b`.
Changes are not committed at this checkpoint; sources.json in the evidence
archive identifies the exact RTL/configuration/tests by SHA256.
Design acceptance/scope is [ADR 0003](../decisions/0003-private-msi-data-caches.md).
This is not a Linux, FPGA, ASIC or unrestricted-N validation result.

## Source and configuration

New ahbmsicache implements separate per-hart, direct-mapped, word-line,
write-back data banks with MSI. The central arbiter exports HOWNER and
continues to order all accesses, including private hits, preserving central
LR/SC and AMO coordination. The SoC adds PRIVATE_DCACHE and
PRIVATE_DCACHE_WORDS; effective MSI requires NCORES > 1. The old shared-cache
and uncached paths remain available. See ADR 0003 for exact transitions,
implicit synchronous snoop acknowledgments, memory attributes and guards.

multicore_msi derives from multicore_coherent: legacy I/D caches, bursts,
Svadu, Svpbmt and CBO extensions are off. The initial full-core matrix uses
8 AHB words per private bank and NCORES=1/2/3; NCORES=1 intentionally bypasses
MSI. UART also exercises the default 256-word capacity on two harts. RV32
checks exercise the isolated arbiter/MSI subsystem, not a full RV32 SoC boot.

## Executed checks and observed results

| Check | Result |
| --- | --- |
| Configuration lint, standard warning policy | PASS: seven standard configs, four existing multicore/shared-cache cases, five MSI parameter cases |
| MSI lint parameters | PASS: 2 harts with WORDS=2/8/256, 3/4 harts with WORDS=8 |
| Single-core structural bypass | PASS: XML elaboration of rv64gc with NCORES=1 and PRIVATE_DCACHE=0/1 contains no ahbmsicache, ahbmulticore or ahbsharedcache instances |
| Arbiter/MSI matrix, WORDS=4 | PASS: RV32/RV64 x 2/3 harts x memory latency 0/3; eight runs, each with directed checks and 2,000 deterministic randomized operations |
| Additional capacities | PASS: RV64/2 harts/WORDS=2/latency=3 and RV32/3 harts/WORDS=8/latency=0, each with 2,000 randomized operations |
| Existing direct tests | PASS: RV32/RV64 CLINT/PLIC, three-master round-robin AHB, central LR/SC/AMO error/reset/locking checks |
| Legacy full-core modes | PASS: two-hart atomic suite at latency 3, uncached and shared-cache paths |
| UART, MSI default capacity | PASS: two harts, latency 3, 256 words/hart, exactly four THR writes, 8,579 cycles |
| Pre-commit and whitespace | PASS on changed/new implementation, tests and engineering documents |

Every directed/random MSI run checks read hits, S sharing, S-to-M upgrade,
M-hit write-back behavior, BusRdX, dirty eviction/intervention, byte strobes,
uncached instruction access to own/remote modified code, MMIO bypass,
LR/SC success/failure including an ordinary M-hit store after LR, AMO
exclusion with an owner instruction fetch, concurrent readers/writers,
failed writeback retention, failed-fill retry and reset during a request.
An independent software reference checks the randomized data; RV64 random
stores populate upper as well as lower bytes. RTL assertions check exclusive
M ownership at the accessed index. This is bounded randomized simulation,
not exhaustive formal verification or proof of liveness for arbitrary N.

Full RV64 cores, PRIVATE_DCACHE=1, WORDS=8:

| Harts | RAM latency | Atomic suite cycles | Memory/IPI/timer smoke cycles |
| --- | --- | --- | --- |
| 1 (MSI bypass) | 0 | 3,679 | 731 |
| 1 (MSI bypass) | 3 | 7,446 | 1,209 |
| 2 | 0 | 22,716 | 2,915 |
| 2 | 3 | 31,788 | 3,925 |
| 3 | 0 | 39,904 | 4,595 |
| 3 | 3 | 56,092 | 6,341 |

The atomic image checks RV64 .w/.d AMOs, upper-word lanes, shared increments,
unique AMO returns, LR/SC loops/conflicts/consumption, a spinlock, reusable
barriers and cross-hart code patching followed by fence.i. All twelve full-core
atomic/smoke runs printed PASS and exited 0. The legacy uncached/shared
atomic cases completed in 16,516/11,933 cycles respectively. These cycle
counts identify executions; the prototype makes no performance-improvement
claim and serializes even private hits.

The full-core testbench now observes modified cache banks as well as RAM
when reading software PASS/FAIL slots. Write-back RAM alone can be stale.
This white-box observer neither flushes nor modifies caches or memory and
does not participate in snoops. Coherence itself is checked independently
by actual CPU loads in the programs and by the subsystem reference model.

## Reproduction and evidence

From the repository root, after successful setup:

```bash
source ./setup.sh
make deriv
python3 tests/multicore/run.py --private-dcache --unit-only --latency 0 3 --work-dir /tmp/wally-msi/units
python3 tests/multicore/run.py --private-dcache --suite atomic --cores 1 2 3 --latency 0 3 --cache-words 8 --work-dir /tmp/wally-msi/full
python3 tests/multicore/run.py --private-dcache --suite uart --cores 2 --latency 3 --work-dir /tmp/wally-msi/uart
```

Run these sequentially: the runner regenerates all derivative configurations
at startup. Regenerating config/deriv while another elaboration reads it
caused transient missing-config.vh build failures during this experiment;
affected builds were rerun after generation completed. Those failed build
logs are retained and are not counted as RTL failures or successful runs.
The installed Verilator also required packed MSI state storage for a single
reset assignment instead of nonblocking reset assignments in large loops.
No warning class was disabled to bypass that elaboration issue.

Tools: Verilator 5.022 development revision v5.020-157-g2b4852048;
bare-metal GCC 13.2.0; G++ 11.4.0; Python 3.10.12; Ubuntu 22.04/WSL2.
uv is absent, so Python entrypoints and the existing temporary pre-commit
installation were invoked directly. Lint uses the repository's lint_config
with only unsupported --quiet removed; standard warning exclusions remain.
MSI full-core/subsystem simulations use the checked-in runners and dpi.cpp,
without the older standard-testbench VL_SYSTEM_IN compatibility shim.
Builds use native Linux /tmp, avoiding case-insensitive .S/.s collisions.

Raw logs/models/helpers are in `/tmp/wally-msi/`. Compact logs, input images,
source/tool manifests, helper scripts and results are copied to ignored
`sim/verilator/wkdir/multicore/verification-msi-20261019/`.
results.json records matrix verdicts/cycles and log hashes; sources.json
identifies source/config/test hashes. These are host-local locators, not a
remote archive. Models and raw logs are not permanent engineering documents.

## Explicit limitations

One synchronous controller serializes all accesses. Separate private-hit
completion, distributed snoop queues, multiword lines, MESI and directories
are not implemented. DMA writers bypassing this fabric are not coherent.
Cache/bus recovery retains dirty data on errors, but existing CPU HRESP
handling does not implement precise exceptions or delayed writeback faults.
Reset discards dirty contents. No full RV32 multicore program, arbitrary-N
Linux support, new Linux boot, coverage closure, FPGA synthesis/routing,
BRAM inference, clock closure, DDR calibration or board test is established.
The prior Linux SMP PASS used a shared cache and remains scoped to its
[earlier record](2026-10-19-multicore-main-integration.md).
