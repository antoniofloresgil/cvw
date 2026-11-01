# Sscofpmf Linux sampling integration

Question: does Wally's optional Sscofpmf implementation deliver overflow
samples to Linux `perf record`, and do its programmable counters distinguish
user from supervisor execution?

Source: `adding-mpu-support` at parent `4fcd9257a`, plus the sampling harness
in this change. Configuration: `pmu_deleg_linux`,
single-core native-cache SoC, 32 counters, Linux 6.19.14, OpenSBI 1.7,
static `perf` from `/tmp/wally-pmu-20261020/linux`. The exact software
capabilities and source hashes are in [PMU software compatibility](../pmu-software-compatibility.md).

The versioned `linux/pmu/sampling_init.c` performs these checks in order:

1. Compare `PERF_COUNT_HW_BRANCH_INSTRUCTIONS` with user-only and
   supervisor-only filters across the same branch-heavy workload.
2. Read sample records from a `perf_event_open` mmap ring after a 1024-event
   user-mode sampling run.
3. Run actual `perf stat` with `branches:u,branches:k` and actual `perf record`
   with `branches:u` at period 1024; parse the resulting `perf.data` for at
   least one `PERF_RECORD_SAMPLE`.

Reproduction after `source ./setup.sh`:

```bash
python3 linux/pmu/delegation_build.py \
    --base-work /tmp/wally-pmu-20261020/linux \
    --kernel-source /home/cad/wally-smp-work/sources/linux-6.19.14 \
    --cross-prefix /home/cad/wally-buildroot/output/host/bin/riscv64-buildroot-linux-gnu- \
    --work /tmp/wally-sscofpmf-linux --jobs 12 --sampling
python3 linux/pmu/run.py --work /tmp/wally-sscofpmf-linux --cycles 150000000
```

Build completed. Image manifest and hashes:
`/tmp/wally-sscofpmf-linux/manifest.json`; build log:
`/tmp/wally-sscofpmf-build.log`. Simulation output and final verdict:
`/tmp/wally-sscofpmf-linux/rtl.log` and `rtl-result.json`.

**Verdict: PASS** for the single-core RTL Linux integration at 143,791,780
cycles. `perf_event_open` measured 120,007 user branches versus 1,600 kernel
branches in the filtered workload, and its overflow mmap ring contained 234
samples. Actual `perf stat -e branches:u,branches:k` completed; actual
`perf record -e branches:u -c 1024` wrote 147 samples, which the init found
as `PERF_RECORD_SAMPLE` records in `perf.data`. The final
`WALLY_PMU_PASS sampling_and_filtering` marker and runner exit code 0 are
both present. No `WALLY_PMU_FAIL` marker appears.

The simulation reused the existing Verilator model because only the software
image and harness changed. Model SHA-256:
`89fc76d3ae02da988f2de8725e2a7448a5887f0ae860515ad5cee65386a9a9f1`;
RAM image SHA-256:
`d77b73eb12e2749e9ca5c839ccd2a8de43ccdf62faa7f7206a3c67f0f05ec15b`;
log SHA-256:
`dde0d4f13ab9821951ec2af6dad154832579edf52c43ce94dbc2d1eb719418fd`.
The runner's `rtl-result.json` also binds the boot ROM, DTB, kernel,
OpenSBI, init, workload and perf binary hashes.

Linux lowered `kernel.perf_event_max_sample_rate` during the direct sample
run because simulated interrupt handling was slow; this did not prevent
sampling or `perf record`. These checks establish function, not sustained
sampling throughput. FPGA implementation, hardware interrupts on the board,
and multicore Linux remain unverified by this single-core run.
