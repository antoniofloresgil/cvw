# Pipelined cache-line transfers

Date: 2026-10-20. Branch `multicore-support`, base
`b72f8852188560c181b8f1bc06e552d497ccf371` plus this working-tree implementation.
Decision: [ADR 0010](../decisions/0010-pipelined-cache-line-bursts.md).

## Question and source scope

Can real AHB address/data pipelining reduce line-fill/writeback cost while
retaining dirty recovery, instruction coherence and banked atomic ordering?
`CACHE_BURSTS` is independent of the core's P.BURST_EN; core interfaces remain
SINGLE. The new engine/mux operate below private MSI, with one home or several.

Tools: Verilator 5.022 development build (v5.020-157-g2b4852048), GNU C++ and
the RISC-V toolchain selected by setup.sh. Source/command/model/log evidence is
under `/tmp/wally-bursts-20261020/` and the ignored archive
`sim/verilator/wkdir/multicore/verification-bursts-20261020/`.
The final source/artifact manifests identify exact inputs; raw logs stay out
of permanent docs. Individual build command/input JSON records are preserved.

## Verification and observed results

Focused verification **PASS**: 13 banked and two one-home controller cases
(30,000 randomized reference operations), 30 full-core executions (21 burst-
enabled, six disabled comparisons, three single-core bypass), 18 lint/structural
checks, four legacy checks, three negative controls and software identity.
Four dedicated engine configurations cover RV32/RV64 at latency 0/3. Every
final model's recorded input hashes match the checked-out RTL/test sources.
Actual SEQ beats and four concurrently active home controllers are observed. A dedicated engine test checks
lengths 1/2/4/8/16/32 on RV32/RV64 at latency 0/3, injects read/write ERROR on
every beat, checks exact accepted/completed counts and cancellation, ends a
burst exactly at a 1 KiB boundary, and aborts/reset-restarts an active burst.
At zero wait it requires N+1 cycles for N words: 4 words take 5 cycles and
32 words take 33 cycles. This proves pipelining beyond a change in HBURST.

The cache scoreboards use a memory model that accepts the next address on the
same edge as the preceding data completion, including waits and two-cycle
ERROR. Additional monitors check stable addresses/write data during stalls,
sequential addresses and burst encoding, MMIO SINGLE behavior and boundaries.
Mixed I/D lines exercise dirty instruction aliases and conservative prefetch.
Existing LR/SC, AMO, byte-store, replacement, intervention and reset checks
remain. A directed mixed-geometry case leaves the first D line absent while a later
D line in the I refill has an M owner. Tests deliberately corrupt data-beat
selection, omit the later dirty-region probe or release a grant early; the scoreboards must reject those mutations.

Final two-hart measurements, fixed 2 KiB per hart each of private I/D,
32-byte lines, latency 3, all local paths and forwarding enabled:

| Homes | Mode | Atomic cycles | Smoke cycles | UART cycles |
| --- | --- | ---: | ---: | ---: |
| 1 | SINGLE baseline | 14,147 | 2,118 | 7,571 |
| 1 | Pipelined bursts | 13,862 | 2,083 | 7,583 |
| 2 | SINGLE baseline | 19,583 | 2,723 | 7,896 |
| 2 | Pipelined bursts | 17,839 | 2,375 | 7,785 |

These measurements use the final transient I-buffer lifetime: it is discarded
on the final refill word and cannot serve as an extra persistent I-cache line.
Initial exploratory numbers were 13,668 / 17,715 atomic cycles; those are
superseded by this final table. Two-home atomic uses **8.91% fewer cycles**;
smoke uses 12.78% fewer. One-home atomic improves by 2.01%, while its UART
case regresses by 12 cycles (0.16%). This is a short-workload comparison, not a DDR3 or
universal throughput claim. Disabled defaults remain one-word lines, one
home and CACHE_BURSTS=0.

## Reproduction

After `source ./setup.sh` from the repository root:

```bash
python3 tests/multicore/run.py --private-dcache --private-icache --local-dcache-reads --local-dcache-writes --cache-to-cache --cache-bursts --coherence-banks 2 --cache-line-words 4 --icache-line-words 4 --cores 2 3 --latency 0 3 --suite atomic --work-dir /tmp/reproduce-bursts
```

`--unit-only` includes the engine's protocol tests and directed/random cache
checks, plus legacy peripheral/bus tests. The focused helpers expand coverage
to four harts/homes, mixed capacities, 16/32-word lines and disabled options.
Linux `build.py --cache-bursts` requires MSI and stores the policy in its
manifest. `run.py` infers it, or validates an explicit `--cache-bursts` or
`--no-cache-bursts`. Model/checkpoint identities distinguish this option.

## Linux scope and remaining evidence

Full burst-enabled Linux RTL is **PASS at 413,832,376 cycles**, launched
`2026-10-20T08:44:26.117004+00:00`. The separately built frozen model uses
two harts/two homes, 256 RV64 words of each I/D capacity per hart, four-word
(32-byte) lines, all local/forwarding paths and CACHE_BURSTS=1, RAM_LATENCY=0.
Model SHA-256: `1c5d8fd55bfd2accf7f68afd316feed073d421e93c512ebbb56968575bb02c0b`.
QEMU reports two CPUs and both counters 128, PASS. Byte-identical checkpoints
at 100k cycles (continuous versus 50k+restore) PASS; bounded probes intentionally
exit INCOMPLETE/75 and are not the full run's verdict.

Linux work: `/tmp/wally-linux-bursts-20261020/`. The full run resumed the
validated 100k checkpoint with 5M checkpoints and a 1.5B-cycle limit. Its
`supervisor-status.json`, `production-process.json`, `rtl.log` and final
`rtl-result.json` record the PASS verdict. The off-repository
`/tmp/wally-bursts-20261020/linux.py` supervises and archives without commit/push.
Initial model/manifest/QEMU/checkpoint evidence is preserved in the archive
above. Recorded production command:

```bash
python3 /tmp/wally-linux-bursts-20261020/frozen-source/linux/smp/run.py --work /tmp/wally-linux-bursts-20261020 --coherence-banks 2 --cache-to-cache --cache-bursts --reuse --resume --checkpoint /tmp/wally-linux-bursts-20261020/resume.checkpoint --checkpoint-interval 5000000 --cycles 1500000000
```

The independent native RTL run exited 0 with two online CPUs and both
shared counters equal to 128. Final log SHA-256:
`c4838a18222158438480997451d146a42ca5a2dd11e64ca2acfcb7d455ee6c86`.
Final evidence is archived as `linux-final-rtl.log`, `linux-final-rtl-result.json`
and `linux-model.json` under the focused verification archive. The supervisor
verified model/image/source identities and all success/failure markers.
The prior two-home SINGLE model passed at 457,165,361 cycles (commit
`b72f88521`); the burst model uses 9.48% fewer cycles with the same software
images, capacity, geometry and local/forwarding options. This is a separate
MSI model, not evidence for MESI or larger caches. No FPGA/DDR3, DMA,
precise writeback exception or arbitrary-hart-count result is claimed.
