# Multiword private instruction/data cache lines

Date: 2026-10-19. Branch `multicore-support`, base `b9dd6e458` plus the multiword-line changes
in the commit containing this record. Status: **PASS for directed/full-core checks; full multiword Linux RTL PASS at 287,836,760 cycles**.
Design: [ADR 0007](../decisions/0007-multiword-private-cache-lines.md).

## Scope and reproduction

After `source ./setup.sh`, a fixed-capacity RV64 32-byte I/D comparison uses:

```bash
python3 tests/multicore/run.py --private-dcache --private-icache --local-dcache-reads --local-dcache-writes --cache-words 256 --icache-words 256 --cache-line-words 4 --icache-line-words 4 --cores 1 2 3 --latency 0 3 --suite atomic --work-dir /tmp/wally-lines-rv64
```

Use line sizes 1/1 for the baseline; RV32 controller tests require 8/8 words
for 32-byte lines. Instruction and data capacities are total words, not lines.
Raw exact-matrix helpers/builds/logs are in `/tmp/wally-multiline/`.
The full-core matrix compares the same programs, capacity and memory latency;
the controller matrix includes unequal geometries and independent enables.

Directed checks exercise full-line dirty intervention/replacement, all word
offsets, allocating byte writes, line-wide ownership invalidation, LR/SC and
AMO, own/remote code modification, concurrent local M commits, local hits
while other harts miss, errors at every D fill/writeback and I fill beat, MMIO
bypass and reset. Deterministic random operations follow directed checks.
Old one-word directed tests remain active in the one-word matrix.

## Results

- PASS: 16 RV32/RV64 controller configurations, including 14 multiword cases,
  two one-word compatibility cases and 32,000 deterministic random operations
  in total. Multiword cases retain independent local-hit/store concurrency.
- PASS: 30 atomic/smoke/UART executions across ten full-core RV64 models,
  including one/two/three harts, waits 0/3, unequal line sizes and independent
  feature enables. One-core results remain 7,446/1,209/7,061 cycles.
- PASS: 20 lint/structural checks: seven ordinary configs, ten private-cache
  parameter cases, the two-hart Linux wrapper and two single-core structural
  removals (requested options off/on, both with multiword geometry).
- PASS: four legacy bus/atomic/peripheral checks; two negative controls reject
  word-only conflict guards and a writeback truncated after its first word.
  The deliberate negative-fixture aborts are expected, not RTL test failures.
- PASS: default DTS byte identity, multiword block/set properties, single-core
  DTS bypass, invalid geometry and explicit manifest mismatch rejection.
- PASS: QEMU with the regenerated 32-byte I/D DTB reports two online CPUs and
  `WALLY_SMP_PASS cpus=2 counter=128 protected=128`.
- PASS: the compiled multiword Linux RTL model restores bit-exact state at
  cycle 100,000 (continuous versus 50,000 plus restore). These bounded probes
  intentionally return INCOMPLETE (75); they do not validate a Linux boot.
- PASS: final code pre-commit checks.

For two harts, 2 KiB **per** I/D bank and RAM_LATENCY=3, measured cycles and
atomic memory transfers are:

| D/I line bytes | Atomic cycles | Smoke cycles | UART cycles | Atomic memory transfers |
| --- | --- | --- | --- | --- |
| 8/8 | 11,687 | 1,918 | 7,415 | 740 |
| 8/32 | 12,059 | 2,113 | 7,526 | 772 |
| 32/8 | 18,937 | 2,051 | 7,475 | 2,269 |
| 32/32 | 19,179 | 2,202 | 7,571 | 2,292 |

The 32/32-byte atomic case takes 64.1% more cycles than 8/8, and memory
transfers rise from 740 to 2,292. Thus larger lines are functional but **not a
performance recommendation for these workloads**. The separate I-only/D-only
geometry cases place most of the added atomic cycles in the D-line change.
Whole-line transfer cost and false sharing are plausible contributors; their
individual contributions are not isolated by this experiment. Defaults stay
one word. The existing RAM model is not FPGA DDR3: latency 0 adds no artificial
waits, and 3 adds three waits. No realistic DDR3/burst performance conclusion
follows from these results. Burst transfers, early restart and direct
cache-to-cache forwarding remain unimplemented.

Exact matrix helpers, commands, per-run cycle/traffic counts, binary hashes,
logs and sources are in the local ignored archive
`sim/verilator/wkdir/multicore/verification-multiword-20261019/`.
`results.json`, `sources.json`, `tool-versions.json` and
`artifact-sha256.json` identify the evidence; build products are not committed.
Tools are Verilator 5.022 development (`v5.020-157-g2b4852048`), bare-metal GCC
13.2.0, host G++ 11.4.0 and Python 3.10.12. No FPGA implementation result exists.

| Identity | SHA-256 |
| --- | --- |
| Verified source manifest | `a3174c02ed26465a80d7147001296d2fb0f5477034f5b921b2fac6c5c98780d7` |
| Frozen Linux source manifest | `c3709aa19b6ec6fe52128f0fac9e0c5b56f1a1cd7efdbd1c2d8d58cb2936a0d2` |
| Multiword Linux model | `964546550c2b824c5c6e9fa003325e4a80b4176168c23f4353a4fba3fcdf3731` |

## Linux boundary

The existing runs in `/tmp/wally-linux-l1-20261019/` and
`/tmp/wally-linux-local-m-20261019/` use their frozen one-word models.
Neither can validate multiword lines. This change wires line geometry through
the Linux build/runner, DTS properties, manifest/model/checkpoint identities
and model directory suffix. Old manifests imply one-word lines; explicit
geometry mismatches are rejected before execution. New geometry requires a
regenerated DTB and boot image. The final Linux result below is scoped to the identified multiword model.

The bounded new model work directory is `/tmp/wally-linux-lines-20261019/`,
with frozen inputs under `frozen-source/` and model directory
`rtl-2-msi-256-i1-256-r1-w1-dl4-il4`. All seven software artifacts are
hash-checked; the DTB and packed RAM were regenerated for the new geometry,
while OpenSBI/kernel/init/ROM remain the previous verified software. The
archive preserves model metadata, image hashes, software images and the exact
three checkpoint commands/logs. A prospective full run must use this source
identity or rebuild a new model, without inheriting an older Linux verdict.
The authorized full run has now **started**, after both predecessors passed.
The conditional gate below has been satisfied. `conditional-launch.py` in the bounded work directory runs detached
and checks both predecessor work directories every 30 seconds. It requires
released runner locks, no active predecessor model, final PASS/exit 0,
matching model/image/log identities and the two-online-CPU/shared-counter
markers. FAIL, INCOMPLETE, missing evidence or identity changes prevent launch.
Only then does it start the frozen runner with `--reuse --resume`, the validated
100,000-cycle `resume.checkpoint`, a 1.5-billion-cycle limit and checkpoints
every five million cycles. The model remains two harts with 32-byte I/D lines.

`conditional-launch-config.json` pins the target runner, model metadata,
images and checkpoint identities; `conditional-launch-status.json` records
WAITING/RUNNING/FINISHED or STOPPED with the reason. `conditional-launch.log`
and `production-runner.log` retain supervisor/runner output. A lock prevents
duplicate supervisors; the runner retains its own work-directory lock. The
eligibility checks were tested against PASS, incomplete/error, missing marker
and identity-mismatch cases. This launched action is not evidence of a completed
multiword Linux boot.

Conditional gate satisfied: stage 5 PASS at 255,818,430 cycles and items 2/3
PASS at 243,089,303 cycles, both exit 0 with two online CPUs and both counters
128. The supervisor launched the frozen multiword model automatically on
2026-10-20 at 00:15:03 Europe/Madrid (2026-10-19 22:15:03 UTC).
`production-process.json` records the exact command/model identity and both
PASS gates. The multiword model has now **PASS at 287,836,760 cycles**, exit 0,
with two online CPUs and both shared counters equal to 128. Launch metadata and a
supervisor-state snapshot are preserved in the multiword archive.

## Final multiword Linux RTL result

**PASS**, documented 2026-10-20. The frozen two-hart model with 32-byte private
I/D lines completed at **287,836,760 cycles**, exit 0, reporting
`WALLY_SMP_ONLINE cpus=2 expected=2` and
`WALLY_SMP_PASS cpus=2 counter=128 protected=128`. The model identity remains
`964546550c2b824c5c6e9fa003325e4a80b4176168c23f4353a4fba3fcdf3731`. Final log SHA-256:
`47bb037e4a51a15c35589d3ccdacce6e2a2b218c76adf11a52f543593763a655`.

Final output and structured result are archived as `linux-final-rtl.log` and
`linux-final-result.json` under the evidence archive named above. Earlier
results/checkpoint probes retain their original capture status. This extends
the directed/full-core checks with Linux SMP for this exact frozen model. It
does not establish burst support, FPGA timing/resources or DDR3 performance.
The documented short-test regression remains; defaults stay one word.
