# Current work

Branch: adding-mpu-support, based on main 82d0b80f7. Synthesizable fixed-function
Zicntr/Zihpm counters, the standard OpenSBI PMU map and Linux perf stat
integration are implemented. Focused checks PASS: six RV32/RV64 CSR/event
cases, seven board DTBs, eight lint configs and full-core HPM coverage.
The real perf/kernel/OpenSBI build and byte-identical checkpoint comparison
also passed. Native Linux PMU **PASS at 121,617,639 cycles**:
all seven counter read/stop checks and actual perf stat succeeded. See the
[experiment](experiments/2026-10-20-sbi-pmu.md) and
[ADR 0013](decisions/0013-sbi-pmu-perf-stat.md) for source/model/log scope.

Hardware is synthesizable; FPGA area/timing and real-board perf remain
untested. Sscofpmf, sampling and privilege filtering are later work. This
branch is separate from multicore-support and its private/coherence event
wiring. Original multicore simulations/capacity work continue independently.
Implementation prepared for commit and publication to origin/adding-mpu-support
after successful native Linux validation.
