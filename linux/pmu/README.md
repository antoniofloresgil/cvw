# Wally SBI PMU counting

These counters are synthesizable RTL, usable on FPGA hardware as well as in
simulation. `csrc.sv` supplies the standard machine CSRs, Zicntr/Zihpm aliases,
counter enables and inhibition. `COUNTERS` includes slots 0-31, with slot 1
reserved; time comes from the CLINT. The standard rv64gc/Linux/FPGA presets
implement 32 slots. The event selectors are fixed-function enables, not a
programmable event multiplexer: zero disables and nonzero enables the slot.

The generated `../devicetree/wally-pmu.dtsi` describes the mapping for unmodified
OpenSBI's generic platform. The matching kernel needs PERF_EVENTS and
RISCV_PMU_SBI. Buildroot selects LINUX_TOOLS_PERF. After booting a matching
bitstream/firmware/kernel/DTB, run as root:

```sh
perf stat -e cycles,instructions,branches,branch-misses,cache-references,cache-misses -- your-program
perf stat -e L1-icache-loads,L1-icache-load-misses -- your-program
perf stat -e r3,r11,r12 -- your-program
```

| Linux event | Counter | Meaning |
| --- | ---: | --- |
| cycles | 0 | Clock cycles, subject to mcountinhibit |
| instructions | 2 | Retired instructions |
| cache-references | 13 | Native L1D accesses, reads and writes combined |
| cache-misses | 14 | Native L1D misses, reads and writes combined |
| branches | 25 | Retired conditional branches, jumps and returns |
| branch-misses | 26 | Mispredicted retired control transfers |
| L1-icache-loads | 16 | Native L1I accesses |
| L1-icache-load-misses | 17 | Native L1I misses |

Raw event n is fixed counter n, for 3-26. The hexadecimal perf spelling matters:
`r11` selects decimal 17 (I-cache misses), and `r12` selects decimal 18
(I-cache stall cycles). Full sources 3-24 retain their existing `csrc.sv`
definitions. Counter aliases can conflict in one group; count them separately
or allow multiplexing. No L1D read/write split is advertised.

The base `pmu_linux` recipe below does not enable overflow interrupt or mode
filtering. Counts include M/S/U execution in that image; use unqualified events
without :u/:k modifiers. The optional `pmu_deleg_linux` configuration enables
Sscofpmf and is exercised by the separate sampling image described below. This
is distinct from Linux's legacy PMU, which exposes only cycles/instructions. A
node for events 25/26 requires the
updated RTL; do not pair it with an older bitstream. For a reduced COUNTERS
configuration regenerate the node and verify which event sources exist:

```bash
python3 linux/pmu/events.py --counters 32 --output linux/devicetree/wally-pmu.dtsi
```

The optional `smcdeleg_*` and `pmu_deleg_*` derivatives implement the
Smcdeleg/Ssccfg CSR path in RTL. This Linux recipe still selects
`pmu_linux`, whose delegation switch is off. To use direct S-mode
programming, firmware must enable `menvcfg.CDE` and delegate the intended
`mcounteren` bits, the device tree must report the actual extensions,
and the kernel must select that path. The present `perf stat` result
therefore does not measure a delegation speedup.

## Reproducible checks

From the repository root after `source ./setup.sh`:

```bash
python3 tests/pmu/run.py --work /tmp/wally-pmu-unit
make -C tests/coverage hpmcounters.elf.objdump hpmcounters.elf.memfile
python3 bin/wsim rv64gc tests/coverage/hpmcounters.elf --sim verilator
```

The Linux integration builds into an isolated work directory with existing
kernel/OpenSBI source trees and a Linux cross-toolchain. It changes no installed
toolchain, SD card, or existing Linux images:

```bash
python3 linux/pmu/build.py --kernel-source /path/to/linux-6.19.14 \
    --opensbi-source /path/to/opensbi-1.7 \
    --cross-prefix /path/to/riscv64-buildroot-linux-gnu- --work /tmp/wally-pmu-linux
python3 linux/pmu/run.py --work /tmp/wally-pmu-linux
```

It builds the actual perf tool, a static init and workload, kernel and OpenSBI.
The 128 MiB, single-core native-cache SoC is independent of multicore-support.
The DTB includes the PMU map and its RAM-image copy is generated from that DTB.
The test init checks standard/raw events through perf_event_open, verifies
start/stop/read behavior and invokes perf stat on the workload. Only the final
`WALLY_PMU_PASS perf_event_open_and_perf_stat` marker establishes integration
PASS. Unit tests, lint, successful builds or earlier multicore/Linux results
do not establish this verdict. `--build-only`, `--reuse` and `--resume` support
frozen model/image fingerprints and 5M-cycle checkpoints. Exit 75 means a
bounded/interrupted run is incomplete. See the
[experiment](../../docs/engineering/experiments/2026-10-20-sbi-pmu.md) for actual
results, tool adaptations and missing FPGA evidence.

## Sscofpmf sampling image

With the same base PMU image, Linux source, and cross-toolchain, build an
isolated `pmu_deleg_linux` image using the versioned workload and init:

```bash
python3 linux/pmu/delegation_build.py --base-work /tmp/wally-pmu-linux \
    --kernel-source /path/to/linux-6.19.14 \
    --cross-prefix /path/to/riscv64-buildroot-linux-gnu- \
    --work /tmp/wally-sscofpmf-linux --sampling
python3 linux/pmu/run.py --work /tmp/wally-sscofpmf-linux
```

The init compares `branches:u` with `branches:k`, collects overflow samples
through `perf_event_open`, then runs actual `perf stat` and `perf record`. It
checks that `perf.data` contains sample records. A PASS requires the
`WALLY_PMU_FILTER_PASS`, `WALLY_PMU_SAMPLING_PASS`, and final
`WALLY_PMU_PASS sampling_and_filtering` markers. See the
[sampling experiment](../../docs/engineering/experiments/2026-10-21-sscofpmf-linux.md)
and [software compatibility](../../docs/engineering/pmu-software-compatibility.md)
for results and the exact Linux/OpenSBI support boundary.

To check the Smcntrpmf filters on fixed counter 0 (`cycles`) and counter 2
(`instructions`), add `--fixed-filter` to the image-build command above and
use a new work directory. The test reads user-only and kernel-only counts via
`perf_event_open`, rejects missing or ineffective filtering, and runs actual
`perf stat` for both modifiers. The runner then also requires
`WALLY_PMU_FIXED_FILTER_PASS`. See the
[fixed-counter experiment](../../docs/engineering/experiments/2026-10-21-smcntrpmf-linux.md)
for the result.
