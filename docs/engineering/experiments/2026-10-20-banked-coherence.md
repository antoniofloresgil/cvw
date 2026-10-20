# Multiple outstanding coherence transactions through address homes

Date: 2026-10-20. Branch `multicore-support`, base
`f71666f0776949f27c4ebdbaa627b5a46a8f5a54` plus the banked implementation in the commit containing this record.
Decision: [ADR 0009](../decisions/0009-banked-coherence-transactions.md).

## Question and configuration

Can independent physical regions make coherence progress simultaneously while
retaining MSI ownership, instruction coherence, LR/SC and AMO semantics?
`COHERENCE_BANKS=2/4` instantiates independent home engines and a common AHB
port arbiter. Capacities remain total per hart; the home count partitions them.
One bank is the unchanged default, and NCORES=1 bypasses coherence entirely.

Tools: Verilator 5.022 development build (v5.020-157-g2b4852048), GNU C++ and
the RISC-V toolchain selected by repository setup.sh. Raw commands, logs,
executables and JSON results are under `/tmp/wally-banked-20261020/` and the
ignored `sim/verilator/wkdir/multicore/verification-banked-20261020/` archive.
Source and artifact SHA-256 manifests identify the actual tested inputs.

## Checks and observed status

Focused verification has **PASS**: ten banked controller configurations
(RV32/RV64, 2/3/4 harts, two/four homes, latency 0/3, mixed I/D capacities
and lines, independently disabled options), plus two one-home controller
regressions: 24,000 randomized operations in total. All 18 full-core
atomic/smoke/UART runs pass (12 banked, three one-home comparisons and three
single-core bypass runs). All 18 lint/structural checks, four legacy checks,
two negative controls and DTS/manifest/CLI checks pass.
The four-hart/four-home RV32 and RV64 directed tests explicitly reached
**four simultaneously active coherence controllers**. The test requires an independent dirty ownership move
to complete before a simultaneous cold RAM miss when forwarding and wait
states are enabled. Tests cover cross-home LR replacement and SC consumption,
remote stores invalidating reservations, concurrent AMO admission, owner IFU
progress in another home, same-home conflicts, partial writeback errors in
each home, fill errors, byte writes, instruction aliases, RAM-port contention,
MMIO bypass and reset with pending requests.

The two-hart/32-byte-line full-core atomic/smoke/UART cases passed at
19,583 / 2,723 / 7,896 cycles, respectively (latency 3, 2 KiB each I/D bank
in total per hart, local paths and forwarding enabled). Three-hart/latency-0
cases also passed. The same-capacity one-home forwarding baseline is
14,147 / 2,118 / 7,571 cycles: routing/bridging costs dominate these short
workloads. Concurrency is demonstrated, not a general performance improvement.
The disabled one-home full-core comparison reproduces the preceding
14,147 / 2,118 / 7,571-cycle results exactly. Single-core structural checks
show no coherence fabric, arbiters or private banks, even when requested.

A concurrent testbench loop triggered host SIGILL in a generated timing
coroutine. The equivalent explicit concurrent request sequences execute;
looped randomized reference operations remain. This is a simulator/testbench
observation, not evidence of an RTL fault or proof of a compiler defect.

## Reproduction

After `source ./setup.sh` from the repository root:

```bash
python3 tests/multicore/run.py --private-dcache --private-icache --local-dcache-reads --local-dcache-writes --cache-to-cache --coherence-banks 2 --cache-line-words 4 --icache-line-words 4 --cores 2 3 --latency 0 3 --suite atomic --work-dir /tmp/reproduce-banked
```

`--unit-only` runs the banked reference tests plus legacy bus/peripheral tests.
Focused matrix helpers and the exact negative mutations are preserved in the
evidence archive. The negative controls remove cross-home reservation clearing
or force all addresses to one home; correct scoreboards must reject both.

Linux artifacts can be regenerated with `linux/smp/build.py` using MSI mode,
`--coherence-banks 2` and matching private-cache options. `run.py` infers the
home count from the manifest or verifies the explicit option. Model names,
fingerprints, results and checkpoint identities include this count.

## Linux and limits

New full Linux RTL validation is **PASS at 457,165,361 cycles**, exit 0. Its newly built
frozen model uses two harts, two homes, total 256 RV64 words each of private
I/D per hart, four-word (32-byte) lines, forwarding and all local paths.
RAM_LATENCY=0. Binary SHA-256: `d2d7f71051e31af1b8ed7060853bfd815ba6834c34bd9a899b14c9156e5166e3`.
QEMU PASS (two CPUs/counters 128) and byte-identical 100k versus
50k+restore checkpoints PASS. Bounded probes intentionally exit 75; their
INCOMPLETE status is not the full run's verdict.

Work directory: `/tmp/wally-linux-banked-20261020/`. Full RTL started at
`2026-10-20T04:23:23.347240+00:00`, resuming the validated 100k checkpoint,
with five-million-cycle checkpoints and a 1.5-billion-cycle limit.
`supervisor-status.json`, `production-process.json`, `rtl.log` and final
`rtl-result.json` identify the actual progress/outcome. The off-repository
`/tmp/wally-banked-20261020/linux.py` supervises and archives the run; the separately authorized publication finisher documents, commits and pushes after PASS. Initial model/manifest/QEMU/checkpoint evidence is in
the archive above. Use this exact frozen command to reproduce/resume:

```bash
python3 /tmp/wally-linux-banked-20261020/frozen-source/linux/smp/run.py --work /tmp/wally-linux-banked-20261020 --coherence-banks 2 --cache-to-cache --reuse --resume --checkpoint /tmp/wally-linux-banked-20261020/resume.checkpoint --checkpoint-interval 5000000 --cycles 1500000000
```

Do not launch a duplicate while its RTL lock is held. The earlier one-home
cache-to-cache Linux passed at 288,425,528 cycles and cannot validate this
implementation. The new two-home model now has its own Linux PASS at 457,165,361 cycles.

Only distinct homes progress independently, with one blocking transfer per
hart. AHB memory beats, same-home requests and global AMOs remain serialized.
RAM_LATENCY in simulation does not model external DDR3. No burst, external DMA
coherence, precise architectural error delivery or FPGA result is claimed.

## Final two-home Linux RTL result

**PASS**, documented 2026-10-20, at **457,165,361 cycles**, exit 0. Verified markers:
`WALLY_SMP_ONLINE cpus=2 expected=2` and
`WALLY_SMP_PASS cpus=2 counter=128 protected=128`.
Model SHA-256: `d2d7f71051e31af1b8ed7060853bfd815ba6834c34bd9a899b14c9156e5166e3`. Final log SHA-256:
`fa9d82b68025451af31825a8d8e3f00a50ad7450112b51f985c03729d18dfee9`. The evidence archive above contains
`linux-final-rtl.log` and `linux-final-result.json`, alongside the image
manifest, model metadata and separate initial QEMU/checkpoint captures.
Earlier bounded probes preserve their intentional INCOMPLETE/75 verdicts.

This validates the exact two-hart/two-home RTL model, including its atomic
ordering. Four concurrent homes remain supported by directed RV32/RV64 and
full-core checks, not by this two-home Linux result. The short-test latency
regression remains documented; one home remains the default. No burst, DMA
coherence, FPGA timing or external DDR3 result is established.
