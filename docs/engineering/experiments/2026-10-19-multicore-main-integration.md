# Main integration into the multicore branch

Status: **INCOMPLETE**, verification running on 2026-10-19.

## Question and source identity

Does the shared-memory multicore implementation still pass after incorporating
main's newer MMU, FP/walker, WFI/hazard, UART and memory-sizing changes?

Merge inputs are feature `f655debaed2bda8dfa7635d1a78a8f32f66bffa7` and
main `82d0b80f7d1471f224fc5a8fc307d75f5eb26f53`, which includes official
upstream `712ee9719467e9e9987cebd55926ae8e01b08770`. The automatic merge
had no text conflicts; its tree before documentation refresh was
`363bf086a623c4f6c623db1c468297096750b13f`. No additional RTL edits have
been made for this integration. The Vivado boards submodule was aligned to
main's `d8d43ed9f3f7e367ee3de82782ed601d88305677`.

Reviewed combinations: the derivative recipes preserve the shared-cache
restrictions; `HART_ID` and `SHARED_ATOMICS` still propagate through each core;
walker-owned `LSUFpLoadStoreM` controls size/data selection while `LSUAtomicM`
keeps PTE accesses out of the shared atomic protocol; `WaitM` connects each
hart's privileged decoder and hazard unit independently. Main's registered
APB error selection and RAM/ROM sizing fixes are retained.

## Environment and reproduction

Source `./setup.sh` before build/simulation. Verilator 5.022
(`v5.020-157-g2b4852048`), bare-metal GCC 13.2.0. This host lacks `uv`;
Python tools run directly, with pre-commit's existing temporary installation.
The installed Verilator lacks `--quiet`: lint uses the repository's flags
without that switch, with no additional warning classes disabled.

Derivatives were generated once with `perl bin/derivgen.pl`, before concurrent
readers. Builds and logs use `/tmp/wally-multicore-main-20261019/`, on a native
case-sensitive filesystem, preserving the prior stage-3 evidence. Local
`bare.py` is the checked-in [runner](../../../tests/multicore/run.py) with only
its output directory changed and redundant derivative regeneration removed.
`linux.py` invokes the checked-in [Linux runner](../../../linux/smp/run.py),
skipping only the already completed derivative-generation command.

```bash
source ./setup.sh
python3 tests/multicore/run.py --suite atomic --shared-cache
python3 tests/multicore/run.py --suite atomic --cores 1 2 --latency 3
python3 tests/multicore/run.py --suite uart --shared-cache --cores 2 --latency 3
python3 linux/smp/run.py --work /path/to/copied-smp-images --sim verilator
```

The Linux run uses copies of the existing two-hart UART-profile images from
`/home/cad/wally-smp-headless`, with a newly generated and compiled RTL model;
no `--reuse` of an old executable. Kernel/firmware/userland inputs are
unchanged from the [original SMP record](2026-10-18-linux-smp.md).
QEMU is not rerun because the software inputs did not change.

The additional ordinary testbench run uses `sim/verilator/Makefile` and the
18 existing directed-test ELFs from main's integration. The installed
Verilator needs the same external `VL_SYSTEM_IN` runtime shim described in
the [main integration record](2026-10-18-upstream-integration.md); it implements
`$system(string)` and does not alter RTL or test verdicts. Precompiled headers
are disabled for that C++ build, as required by the external header injection.

## Results

Completed checks on the combined sources:

- PASS: all seven standard lint configurations plus `multicore` (3 harts),
  `multicore_atomic` (3), `multicore_coherent` (3, shared cache) and
  `multicore_linux` (2, shared cache).
- PASS: direct CLINT/PLIC RV32/RV64, AHB arbitration, LR/SC reservation and
  AMO exclusion/error/reset tests, plus shared-cache hit/miss/subword/MMIO,
  lock/error/reset behavior.
- PASS: shared-cache atomics and memory/IPI/timer tests for 1/2/3 harts with
  RAM latencies 0 and 3, including cross-hart instruction modification and
  `fence.i`. Cycle counts match the original stage-3 matrix below.
- PASS: uncached atomic and memory/IPI/timer tests for 1/2 harts, latency 3:
  7446/1209 and 16516/2082 cycles respectively.
- PASS: dual-hart shared-cache UART/subword test, latency 3, 7310 cycles;
  exactly four THR writes.
- PASS: 15 RV64 and 3 RV32 directed RTL tests, including fault/spill handling,
  FP/PTE ownership, WFI, Svinval and UART regressions. Both ordinary-testbench
  runs ended with `SUCCESS! All tests ran without failures.` See `rv64.list`,
  `rv32.list` and `directed-results.json` in the evidence for the exact inputs.
- PASS: pre-commit on 118 existing/added files, excluding deleted files and
  separately versioned addins; documentation links and image hashes checked.

| Harts | RAM latency | Atomic cycles | Memory/IPI/timer cycles |
| --- | --- | --- | --- |
| 1 | 0 | 7092 | 1256 |
| 1 | 3 | 8481 | 1461 |
| 2 | 0 | 9707 | 1403 |
| 2 | 3 | 11933 | 1699 |
| 3 | 0 | 14041 | 1782 |
| 3 | 3 | 17344 | 2141 |

Linux SMP is still in progress. Do not treat the original stage-3 Linux PASS
as a verdict on these combined sources.

## Evidence and limits

Working evidence: `/tmp/wally-multicore-main-20261019/`; `sources.json` records
source and effective-configuration SHA-256 hashes. Local wrappers, build logs,
run logs and copied image manifest preserve the actual procedure. These are
host-local artifacts, not a durable remote archive.

No FPGA, ASIC, full nightly, lockstep, arbitrary-N Linux, private-cache
coherence or external-DMA verification is claimed.
