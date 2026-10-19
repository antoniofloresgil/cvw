# Current work

Checkpoint: 2026-10-19, `multicore-support`, working tree based on
`35cb2093bc4af2b0549fc529879b6748006fee9b` (published to origin).
That revision integrates `main:82d0b80f7` and official upstream `712ee9719`.
Use `git status` and `git rev-parse HEAD` for the actual checkout state.
This checkpoint does not select branches automatically.

## Objective and implementation

Implement the user's first private-cache step: two harts initially, MSI
bus snooping, one coherence transaction in flight, with parameterized hart
count/capacity and automatic removal of coherence when NCORES=1.
The working tree adds separate per-hart write-back data-cache banks and the
blocking MSI controller described in [ADR 0003](decisions/0003-private-msi-data-caches.md).
All accesses, including private hits, still cross the central arbiter so
LR/SC and AMO keep their existing ordering point. Instructions remain uncached
but snoop modified data. The older uncached/shared-cache modes remain.

Executed checks passed: 16 lint cases, two single-core structural checks,
10 directed/random MSI runs, the full RV64 1/2/3-hart atomic/smoke matrix,
legacy modes and default-capacity UART. Source and result scope are in the
[MSI experiment](experiments/2026-10-19-private-msi.md). The earlier
[combined-source integration](experiments/2026-10-19-multicore-main-integration.md)
is a separate completed result, including two-hart Linux SMP with the shared
cache. That Linux result does not validate Linux with the new private caches.

Completed task: Linux SMP with private MSI **PASS** on two RTL harts at
**629,148,416 cycles**, exit 0, with 256 words per private bank. Linux reports
two online CPUs and both shared counters equal to 128. The QEMU software
reference, RTL build/lint, bit-exact checkpoint restoration, signal-driven
save/restore and runner identity/locking checks also pass. No simulation is
running. See the [Linux MSI record](experiments/2026-10-19-linux-msi.md) for
identities, reproduction and the preserved evidence.
The implementation and validation records are included in the commit containing
this checkpoint; use Git history and remote refs for publication status.

## Boundaries and remaining work

- Private-hit concurrency, nonblocking cache requests, larger multiword lines,
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
2. Add private instruction caches with explicit instruction synchronization tests.
3. Add independent local-hit completion only with revised reservation/snoop
   coordination and verification; do not silently hide stores from the arbiter.
