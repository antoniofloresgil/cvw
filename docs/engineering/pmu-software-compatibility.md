# PMU software compatibility on `adding-mpu-support`

Checked at Wally `4fcd9257a` on 2026-10-21. These are **examined versions**, not
claims about the earliest release with support. The Linux source is
`linux-6.19.14` from `/home/cad/wally-smp-work/sources/`; OpenSBI is `1.7`
from `/home/cad/wally-buildroot/output/build/`. The image built by
[`linux/pmu/delegation_build.py`](../../linux/pmu/delegation_build.py) uses
both, the `pmu_deleg_linux` RTL configuration, and the matching PMU device
tree. Other kernels or firmware revisions need their own source audit and
integration run.

| Capability | OpenSBI 1.7 in this tree | Linux 6.19.14 in this tree | Integration evidence |
| --- | --- | --- | --- |
| Zicntr/Zihpm and SBI PMU counting | Discovers counters and uses the device-tree event map | `riscv_pmu_sbi.c` exposes events to `perf stat` | PASS with actual `perf stat`; see [PMU integration](experiments/2026-10-21-pmu-main-integration.md) |
| Sscofpmf overflow and sampling | Detects `scountovf`; configures `mhpmeventN.OF` and the overflow interrupt | Detects Sscofpmf, installs the overflow IRQ, and services samples through the SBI PMU driver | See [Sscofpmf integration](experiments/2026-10-21-sscofpmf-linux.md) for the separate `perf record` result |
| Sscofpmf programmable-counter mode filtering | Translates SBI PMU filter flags into `mhpmeventN.{MINH,SINH,UINH}` | Sends `exclude_kernel`/`exclude_user` flags for event modifiers such as `:u`/`:k` | See [Sscofpmf integration](experiments/2026-10-21-sscofpmf-linux.md) |
| Smcntrpmf fixed-counter filtering | Detects `mcyclecfg` and configures fixed-counter inhibit bits | Can request SBI PMU privilege filters, but does not explicitly advertise Smcntrpmf | RTL-directed tests pass; Linux fixed-counter filtering has not been measured |
| Smcdeleg + Ssccfg | Detects Smcdeleg and enables `menvcfg.CDE` | The standard SBI PMU driver still configures, starts, and stops counters through SBI calls; it does not use the delegated CSR fast path | A custom S-mode kernel probe passed; stock `perf` direct programming remains unsupported by this kernel. See [delegation experiment](experiments/2026-10-21-smcdeleg-ssccfg.md) |

The extensions must also be enabled in the elaborated Wally configuration and
advertised accurately in the device tree. The base `pmu_linux` image does not
enable the optional extensions. A software feature present in these source
versions does not by itself establish working hardware or end-to-end behavior.

Source anchors for this assessment: OpenSBI
`lib/sbi/sbi_hart.c` (SHA-256
`9adee98104312e7b94e9e96e71054e330aab6407339cef7a76841711b7c9b053`),
OpenSBI `lib/sbi/sbi_pmu.c` (SHA-256
`7f2d69c190b13e0dc1718166f99fdd984500aab69a4beb37f5922bc9be708e58`),
and Linux `drivers/perf/riscv_pmu_sbi.c` (SHA-256
`26816f5455683e182f202f239c8e248e7955461e0326333d4110a018353aa316`).
The relevant Linux PMU driver has no Smcdeleg/Ssccfg direct programming path
in this source snapshot.
