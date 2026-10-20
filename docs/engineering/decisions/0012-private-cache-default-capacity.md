# ADR 0012: Planned 8 KiB private-cache defaults

Status: **proposed**, pending completion of the burst/MSI and MESI Linux
validations on `multicore-support`. Requested 2026-10-20. This record does not
claim the values have already changed or that the FPGA can implement them.

The user requested 8 KiB per private instruction and data cache per hart,
after the current protocol validations pass. Keep all sizes configurable and
retain smaller controller/stress fixtures to provoke replacements and conflicts.
Private RTL defaults should use `8192/(P.AHBW/8)`: 1,024 RV64 or 2,048 RV32
words. Linux RV64 private-mode builders/DTB defaults should use 1,024 words.
Shared-cache and explicitly sized historical tests keep their previous values;
old manifests retain their original capacity interpretation.

The deferred workflow in `/tmp/wally-default8k-20261020/` prepares a seven-file
overlay and verifies RV32/RV64 elaborated defaults and explicit DTS overrides.
It must not apply the overlay until both frozen 2 KiB Linux baselines pass,
with matching model/log/image identities. It must stop on failures, a branch
change or edits to guarded sources rather than overwrite concurrent work.

After applying, rerun small-cache reference checks and matched two-hart/two-home
2 KiB versus 8 KiB full-core atomic/smoke/UART/exclusive tests at RAM_LATENCY
0 and 3. Keep MESI, local paths, forwarding, bursts and 32-byte lines identical.
Then run a fresh 8 KiB RTL Linux model with RAM_LATENCY=0, regenerate the DTB
and RAM image, and compare final cycles against the existing 2 KiB MESI model.
Retain exact source, software and executable hashes. A larger cache is not
assumed to improve every workload or FPGA frequency.

Single-core coherence bypass remains unchanged. This changes neither the
protocol selection default nor home count, line size or concurrency limits.
A later FPGA synthesis will assess dual-core Nexys Video area/timing/BRAM use;
32 KiB of dual-core private I/D data capacity excludes metadata and buffers.
No synthesis is authorized as part of this capacity follow-up. No automatic
commit/push is requested.
