# Main integration into the multicore branch

Status: **PASS**, completed on 2026-10-19. Short checks and dual-hart Linux
SMP passed on the combined sources. Local merge commit: `d4378148d` (not pushed).

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
(`v5.020-157-g2b4852048`), bare-metal GCC 13.2.0, host g++ 11.4.0 and
Python 3.10.12 on WSL2. `tool-versions.json` preserves full version strings.
This host lacks `uv`;
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
`/home/cad/wally-smp-headless`, with a newly generated and compiled RTL model.
The continuation described below preserves that merged RTL and the image
inputs; it does not reuse a pre-merge model. Kernel/firmware/userland inputs are
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

Linux SMP **PASS** on the actual two-hart Wally RTL, with the merged sources,
128 MiB RAM, Sv39/Svade and a shared cache of 256 words. Process exit code: 0.
The static initramfs checked online CPUs, worker affinity and exit status,
an atomic counter, and a spinlock-protected counter:

```text
WALLY_SMP_ONLINE cpus=2 expected=2
WALLY_SMP_PASS cpus=2 counter=128 protected=128
PASS: Linux SMP on Wally RTL after 261982868 cycles
```

This is a new combined-source result, separate from the older `f655debae`
result. `linux-results.json` records the log hash and source/model/image
manifests. No simulation is left running.

## Interrupted run and checkpointed continuation

The first combined-source simulation stopped after the last reported
104,000,000 cycles, with no PASS, FAIL or timeout verdict. When continuing,
its process was absent and the environment's container had been replaced.
This is **INCOMPLETE**, not an RTL failure. `linux/initial-rtl.log` preserves
that attempt. A fresh run of the unchanged model was deliberately stopped to
switch to a checkpoint-capable local harness; `linux/pre-checkpoint-rtl.log`
preserves it, also without a Linux verdict.

To avoid losing hours of simulation on another environment interruption, a
local copy of `linux/smp/sim_main.cpp`, `sim_main_checkpoint.cpp`, adds
Verilator `--savable` support. It serializes the complete RTL model, context,
cycle counter, console-line recognizer and next heartbeat after a complete
clock cycle. Every 5 million cycles it atomically replaces `linux/linux.checkpoint`;
SIGTERM/SIGINT requests a save at the next cycle boundary. This is local
verification tooling, not a new checked-in SoC or runner feature.

Checkpoint validation **PASS**: uninterrupted execution to cycle 100,000 and
execution stopped at 50,000 then restored and advanced to 100,000 produced
byte-identical complete serialized states (SHA-256
`e80cdf1954467c4b9671b821e63dbee0ed91b2b8544c500837803b2d7dbc715f`).
These three bounded harness checks deliberately end at their cycle limits
(exit 1); they are not failed full-Linux runs. `checkpoint-validation.json`,
`test-checkpoint.py` and its three logs preserve the criterion and procedure.

The checkpoint-capable model's PC/mcause probes also matched all 104 common
samples of the original merged model, through 104 million cycles. See
`compare-model-traces.py` and `checkpoint-trace-comparison.json`. The full
successful Linux run used the checkpoint-capable model continuously from
reset; checkpoint restoration itself was validated by the bounded test above.

The checkpoint-capable model SHA-256 is
`e8c2b4e714bf888badc5d3019897dedfb33658fa273d376ce8d4ba888d041465`.
Before starting or restoring, the local launcher verifies this binary, its
C++ harness, and all 623 source/configuration hashes. Build commands are in
`build-checkpoint.py` and `checkpoint-build-run.log`; no RTL/configuration
changes were made for saving state. To continue after an interruption, first
check that there is no existing model process, then run:

```bash
pgrep -af '[V]linux_tb'
python3 /tmp/wally-multicore-main-20261019/start-linux-checkpoint.py
```

The launcher rejects duplicate model processes and archives stale exit status
before starting. Its shell helper sources setup, restores the checkpoint if
present, appends the actual UART/progress/verdict log to `linux/rtl.log`, and writes the process
exit code to `linux-checkpoint-exit-code.txt` on termination. Exit 75 denotes
an interrupted, saved run, not PASS. The Linux success criterion remains
`WALLY_SMP_PASS cpus=2 counter=128 protected=128` and process exit 0.

## Evidence and limits

Working evidence: `/tmp/wally-multicore-main-20261019/`; a copy of completed
logs and helpers is kept in the ignored
`sim/verilator/wkdir/multicore/verification-main-20261019/`. The live checkpoint
and generated model remain in the working evidence directory. `sources.json`
records source and effective-configuration SHA-256 hashes. Local wrappers, build logs,
run logs and copied image manifest preserve the actual procedure. These are
host-local artifacts, not a durable remote archive.

No FPGA, ASIC, full nightly, lockstep, arbitrary-N Linux, private-cache
coherence or external-DMA verification is claimed.
