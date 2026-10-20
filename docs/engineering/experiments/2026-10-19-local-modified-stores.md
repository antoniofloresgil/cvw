# Local modified stores and Linux validation of items 2 and 3

Date: 2026-10-19. Branch: multicore-support, Git base `8ac2d4d6b` plus
uncommitted stage-5/item-2/item-3 changes. **Directed/full-core verification and two-hart Linux RTL PASS.**
See [ADR 0006](../decisions/0006-local-modified-stores.md) for commit ordering.
The [item-2 result](2026-10-19-independent-read-write.md) is the comparison
baseline, not proof for the new local-write ports.

## Test scope and reproducibility

After `source ./setup.sh`:

```bash
python3 tests/multicore/run.py --private-dcache --private-icache --local-dcache-reads --local-dcache-writes --unit-only --latency 0 3 --work-dir /tmp/wally-local-m-unit
python3 tests/multicore/run.py --private-dcache --private-icache --local-dcache-reads --local-dcache-writes --suite atomic --cores 1 2 3 --latency 0 3 --work-dir /tmp/wally-local-m-soc
```

Raw logs/models and exact matrix helpers are in `/tmp/wally-local-m/`.
Sixteen controller cases cover RV32/RV64, two/three harts, waits 0/3, capacities
2/4/8 and all eight I/read/write enable combinations. Each includes directed
checks plus 2,000 deterministic random operations. Eleven full-core models
execute atomic, smoke and UART images, including one/two/three harts, default
256-word banks, independent enables and a rebuilt item-2 baseline. All 16 controller cases and all 33 full-core executions pass. Config generation is not run
concurrently with these bare-metal builds.

New directed checks require parallel M stores without a global request,
parallel stores during a third hart's miss, partial M writes observed by peers,
same-value own-reservation consumption, AMO exclusion, snoop downgrade/retry,
a coincident local store/new LR and a coincident local store/unrelated I fill.
Existing item-2 overlap, errors, reset and code-patching tests remain active.

## Observed results

- PASS: 20 lint/structural checks, including single-core elaboration with all
  optional enables requested and no multicore/cache controller remaining.
- PASS: 16 controller configurations, 32,000 deterministic random operations
  and the directed ordering/coherence checks listed above.
- PASS: 33 full-core atomic/smoke/UART executions across 11 models.
- PASS: four legacy bus/atomic/peripheral checks and four negative controls.
  The negative fixtures deliberately remove reservation notifications, the
  global-read conflict guard, new-LR address priority or I-fill priority;
  each is rejected by its intended directed check.
- PASS: DTS/manifest/CLI compatibility, QEMU two-CPU reference
  (`counter=128 protected=128`), bit-exact checkpoint restoration with the new
  Linux model, and final code pre-commit checks.

Full-core cycle counts (all three suites PASS):

| Case | Harts | Waits | I/read/write enables | D/I words | Atomic | Smoke | UART |
| --- | --- | --- | --- | --- | --- | --- | --- |
| prior | 2 | 3 | 1/1/0 | 8/64 | 12325 | 1943 | 7448 |
| both | 2 | 3 | 1/1/1 | 8/64 | 12047 | 1927 | 7415 |
| both-zero | 2 | 0 | 1/1/1 | 8/64 | 10151 | 1544 | 7177 |
| single | 1 | 3 | 1/1/1 | 8/64 | 7446 | 1209 | 7061 |
| single-zero | 1 | 0 | 1/1/1 | 8/64 | 3679 | 731 | 6725 |
| three | 3 | 3 | 1/1/1 | 8/64 | 18311 | 2685 | 7798 |
| three-zero | 3 | 0 | 1/1/1 | 8/64 | 14326 | 2077 | 7423 |
| default | 2 | 3 | 1/1/1 | 256/256 | 11687 | 1918 | 7415 |
| writes-only | 2 | 3 | 0/0/1 | 8/64 | 31548 | 3880 | 8549 |
| i-writes | 2 | 3 | 1/0/1 | 8/64 | 12363 | 1954 | 7489 |
| rw-only | 2 | 3 | 0/1/1 | 8/64 | 31418 | 3850 | 8479 |

The rebuilt item-2 baseline takes 12,325 atomic cycles; enabling local M stores
with the same two-hart geometry takes 12,047 (278 fewer, 2.26%). This is one
bare-metal workload, not a Linux speedup or FPGA timing/resource measurement.
The testbench local-traffic counter now counts both local reads and M commits;
downstream memory transfers remain a separate measurement.

Tools: Verilator 5.022 development (`v5.020-157-g2b4852048`), bare-metal GCC
13.2.0, host G++ 11.4.0 and Python 3.10.12. Exact commands, configurations,
logs, tool versions and result JSON are preserved in the local ignored archive
`sim/verilator/wkdir/multicore/verification-local-m-20261019/`.
Its `sources.json` SHA-256 is
`88bba70fadb6beecb5ecfce6900ed5891a3cb326a8c25a5a223b40c33730aab5`.
The archive includes input sources, negative fixtures, Linux images/model
metadata and an `artifact-sha256.json` manifest. It is local evidence, not a
published remote artifact.

## New Linux run: items 2 and 3

Started on 2026-10-19 at 20:27:25 UTC in
`/tmp/wally-linux-local-m-20261019/`, after the checks above passed.
Final status: **PASS at 243,089,303 cycles**, exit 0, with two online CPUs
and `counter=128 protected=128`. This validates items 2 and 3 in the frozen
one-word model identified below; it does not validate later multiword changes.
The separate `/tmp/wally-linux-l1-20261019/` run retains its older binary and
validates neither item 2 nor item 3.

The new model has two harts, private MSI D caches and private I caches of 256
words each (2 KiB per bank), local D reads and local M stores enabled. There
is still only one global miss/coherence transaction in progress. RAM is
128 MiB; Linux uses Sv39/Svade, with Svadu/PBMT/CBO disabled. Software is
Linux 6.19.14, OpenSBI 1.7 and Buildroot 2026.02.3-dirty (Linux GCC 15.2.0).
The seven software artifacts were hash-checked and reused unchanged from the
previous run; enabling local writes does not change DTS geometry.

Identities:

| Artifact | SHA-256 |
| --- | --- |
| Frozen `source-snapshot.json` | `9193659715ff5d5a708ef34d6791909fce90176ce9d98e3aad5ffa804534757f` |
| New `Vlinux_tb` | `c479b9e6d29416f83dac59a32cf3c2b59ceea77c1a038df98347f50ce1c6835f` |
| `ram.memfile` | `14df14170ae895abc3819f214b3d61c6788ecda9b156dfc9ab88dc7033c6b70d` |
| `wally-smp.dtb` | `aeba335c578f766ebd840a02743ada733e7909dddb6ce73553216554c043a508` |

`source-identity-check.json` verifies the frozen initial inputs against the
verified checkout, model input hashes against that frozen root, and generated
configuration bodies against the tested definitions. The compiled model and
checkpoint identity include `local_dcache_writes`; model directory:
`rtl-2-msi-256-i1-256-r1-w1`. Remaining software hashes are in `results.json`
and the archived Linux manifest.

Before production, continuous execution to 100,000 cycles was compared with
50,000 cycles plus restore to 100,000: serialized states match exactly.
Production resumes that validated 100,000-cycle snapshot of this same binary,
with a 1.5-billion-cycle limit and checkpoints every five million cycles.
The bounded probes intentionally return INCOMPLETE (75); their initial
`rtl-result.json` is not a production failure. The production runner replaces
that result when it terminates.

The detached command is recorded in `production-process.json`; after an
interruption, with no other runner using this work directory, resume using
its frozen runner rather than the mutable checkout:

```bash
source ./setup.sh
python3 /tmp/wally-linux-local-m-20261019/frozen-source/linux/smp/run.py \
  --work /tmp/wally-linux-local-m-20261019 \
  --private-icache --local-dcache-reads --local-dcache-writes \
  --reuse --resume \
  --checkpoint /tmp/wally-linux-local-m-20261019/resume.checkpoint \
  --cycles 1500000000
```

Follow `rtl.log` for RTL/UART output and `production-runner.log` for runner
messages. Final acceptance still requires the RTL Linux test's two online
CPUs and shared-counter PASS markers. QEMU and bare-metal success do not
substitute for that pending result. No FPGA or external-DMA result is claimed.

Final Linux output/result are preserved as `linux-final-rtl.log` and
`linux-final-result.json` in the local-M archive. Final log SHA-256:
`9eaa961d44b05d0f1b99c6f5cc921d40fee27ca884d6546302d24b3936d6cf25`. The original `results.json` remains its
in-progress capture; final evidence is separate and retains the same model
and image identities.
