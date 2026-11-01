# Smcntrpmf fixed-counter filtering under Linux

Question: do Linux `perf` user/kernel filters reach Wally's *fixed* cycle and
instruction counters through OpenSBI, rather than merely filtering
programmable HPM counters?

Source: `adding-mpu-support` parent `2184dc91c` with the test harness in this
change. Configuration: `pmu_deleg_linux`, one hart, 32 counters. The isolated
image uses Linux 6.19.14, OpenSBI 1.7, and static `perf` from the earlier PMU
build. Wally's device-tree PMU map assigns `cycles` only to counter 0 and
`instructions` only to counter 2, so these events cannot silently use a
programmable counter. OpenSBI 1.7's `pmu_fixed_ctr_update_inhibit_bits` sets
`mcyclecfg`/`minstretcfg` according to Linux's SBI filter flags.

The `--fixed-filter` option in `linux/pmu/delegation_build.py` enables the
additional `sampling_init.c` check. It separately reads `cycles:u`,
`cycles:k`, `instructions:u`, and `instructions:k` via `perf_event_open`
across the same 60,000-round user workload. Both kernel counts must be
nonzero, and each user count must exceed its kernel-only count by at least
four times. This rejects a filter ignored by hardware, since such readings
would both include the dominant user workload. It then invokes actual
`perf stat` for user-only and kernel-only fixed events. The previous branch
filter and sampling/`perf record` checks are rerun in the same image.

Reproduce after `source ./setup.sh`:

```sh
python3 linux/pmu/delegation_build.py \
    --base-work /tmp/wally-pmu-20261020/linux \
    --kernel-source /home/cad/wally-smp-work/sources/linux-6.19.14 \
    --cross-prefix /home/cad/wally-buildroot/output/host/bin/riscv64-buildroot-linux-gnu- \
    --work /tmp/wally-smcntrpmf-linux --jobs 12 --sampling --fixed-filter
python3 linux/pmu/run.py --work /tmp/wally-smcntrpmf-linux --cycles 200000000
```

Image manifest: `/tmp/wally-smcntrpmf-linux/manifest.json`; build log:
`/tmp/wally-smcntrpmf-build.log`; RTL log and result:
`/tmp/wally-smcntrpmf-linux/rtl.log` and `rtl-result.json`. The run reuses
the unchanged `pmu_deleg_linux` Verilator model with SHA-256
`89fc76d3ae02da988f2de8725e2a7448a5887f0ae860515ad5cee65386a9a9f1`.
RAM-image SHA-256:
`ff50886be176ab3ef59888249b3beaea1b415123a4268f38a65631aea9e47c1d`.

**Verdict: PASS** at 163,215,722 RTL cycles, with runner exit code 0.
The direct `perf_event_open` readings were:

| Fixed event | User-only count | Kernel-only count |
| --- | ---: | ---: |
| `cycles` / counter 0 | 925,961 | 28,262 |
| `instructions` / counter 2 | 900,030 | 10,020 |

Both kernel counts were nonzero and each user count exceeded its kernel-only
count by more than four times. Actual `perf stat` runs also completed:
`cycles:u=1,072,708`, `instructions:u=1,023,317`, then
`cycles:k=380,260`, `instructions:k=209,485`. These are separate process runs
with different setup overhead and should not be used as paired U/S ratios;
the direct API readings above use the same 60,000-round workload for each
filter. The log contains `WALLY_PMU_FIXED_FILTER_PASS cycles_and_instructions`.

The existing branch filter and Sscofpmf checks also passed in this image:
120,007 user versus 1,600 kernel branches, 234 direct overflow samples,
and 147 sample records written by actual `perf record`. The runner required
all relevant PASS markers and rejected any `WALLY_PMU_FAIL` marker. Log
SHA-256:
`635c50d89c75685f3d44e5edc58dea21ce8fcc1dafc2d4fe18d2e1f4ff8f5728`.
The result file binds the exact image and model hashes.

The test is single-core simulation only. Linux reduced its maximum sampling
rate during overflow testing because interrupts are costly in the simulator;
this does not invalidate the fixed-counter filter result. FPGA timing, board
behavior, and SMP remain outside this evidence.
