# Current work

Checkpoint: 2026-10-19, `multicore-support`, stage-5 checkpoint commit based on
`8ac2d4d6b67f62cda42f3a0a41d7581ebdf5266e` (published to origin).
That revision integrates `main:82d0b80f7` and official upstream `712ee9719`.
Use `git status` and `git rev-parse HEAD` for the actual checkout state.
This checkpoint does not select branches automatically.

## Objective and implementation

Local M-hit stores are implemented, and a fresh Linux run is now validating both the independent read/write overlap (item 2) and local
stores (item 3). LOCAL_DCACHE_WRITES and the commit sideband are described in
[ADR 0006](decisions/0006-local-modified-stores.md). All 20 lint/structural
checks, 16 controller cases (32,000 random operations), 33 full-core runs,
four legacy checks and four negative controls pass. QEMU, software identity
and bit-exact checkpoint restoration also pass. See the
[local-M record](experiments/2026-10-19-local-modified-stores.md).

Stage 5 adds optional private instruction caches and concurrent read
hits, extending the private MSI baseline. This checkpoint adds
PRIVATE_ICACHE, PRIVATE_ICACHE_WORDS and LOCAL_DCACHE_READS as described in
[ADR 0004](decisions/0004-private-instruction-caches.md). All default enables
remain off, NCORES still defaults to one and the single-core path eliminates
coherence and these new banks. Instruction and ordinary data read hits can
complete independently. Permission acquisition, atomics and misses retain the
global bus path; local M commits notify the central ordering logic. Every correct store invalidates matching I words in all
harts. The current refinement allows local read hits during writes to other
physical words, while retaining a whole-word conflict guard and D-read
blocking across AMO exclusion. See
[ADR 0005](decisions/0005-independent-read-write-overlap.md). Legacy uncached/shared modes remain available.

Executed checks passed: 16 lint cases, two single-core structural checks,
10 directed/random MSI runs, the full RV64 1/2/3-hart atomic/smoke matrix,
legacy modes and default-capacity UART. Source and result scope are in the
[MSI experiment](experiments/2026-10-19-private-msi.md). The earlier
[combined-source integration](experiments/2026-10-19-multicore-main-integration.md)
is a separate completed result, including two-hart Linux SMP with the shared
cache. That Linux result does not validate Linux with the new private caches.

The committed baseline Linux SMP with private MSI **PASS** on two RTL harts at
**629,148,416 cycles**, exit 0, with 256 words per private bank. Linux reports
two online CPUs and both shared counters equal to 128. The QEMU software
reference, RTL build/lint, bit-exact checkpoint restoration, signal-driven
save/restore and runner identity/locking checks also pass. These results predate stage 5. See the [Linux MSI record](experiments/2026-10-19-linux-msi.md) for
identities, reproduction and the preserved evidence.
Current verification: stage-5 wrapper lint and single-core structural removal
pass, as do DTS/manifest checks and the QEMU reference. Twelve controller configurations (24,000 randomized operations), 27 full-core
executions, bus/atomic/peripheral checks and bit-exact checkpoint restoration
pass. The two-hart atomic comparison improves from 31,788 to 12,778 cycles
with both options (8-word D / 64-word I banks, latency 3). A separate Linux
RTL run with default-capacity I/D banks is running; see the [stage-5 record](experiments/2026-10-19-private-l1.md).
Independent read/write overlap is implemented. Its 17 lint/structural checks,
12 controller cases (24,000 random operations), 27 full-core executions and two
negative controls pass. The two-hart atomic comparison drops from 12,778 to
12,325 cycles (3.55% fewer); see the
[new result record](experiments/2026-10-19-independent-read-write.md).
The older stage-5 Linux binary predates both refinements and cannot validate
them. A new run in `/tmp/wally-linux-local-m-20261019/` now contains items 2
and 3, with frozen sources, a separate model and validated checkpoints. It
started at 20:27:25 UTC on 2026-10-19 and remains **INCOMPLETE/running**; see
the local-M record for identities and the exact resume command. The new
two-hart atomic comparison drops from 12,325 to 12,047 cycles (2.26% fewer).
This checkpoint commits stage 5 and both refinements with the full Linux
RTL validation still pending. Directed/full-core PASS results do not establish
a Linux SMP PASS for this revision.

## Boundaries and remaining work

- Nonblocking cache misses, larger multiword lines,
  MESI/directory protocols and external-DMA coherence are not implemented.
- Existing CPU HRESP handling does not provide precise cache/writeback
  exceptions. Cache/bus error tests establish dirty-data retention and retries,
  not architectural fault delivery. Reset discards dirty cache contents.
- No FPGA synthesis/route/resource/timing result or board test is claimed for
  MSI. Two/three-hart tests do not establish arbitrary-N behavior.
- Multicore remains separate from main. `opensource-fpga-bitstream:f950a7753`
  now separately contains main; open DDR3 bring-up still needs hardware access
  and has no new calibration or Wally-boot verdict.
- The pre-existing untracked `addins/riscv-arch-test-cvw/` and
  `addins/riscv-dv/` directories remain untouched. Logs/models are local ignored
  or external evidence, not remote archives.

## Future work conditional on the user's objective

1. With tools/board access, measure FPGA resources/timing and validate hardware.
2. Evaluate larger lines and additional miss concurrency with targeted tests.
3. Evaluate MESI only after measuring remaining ownership-upgrade traffic.
