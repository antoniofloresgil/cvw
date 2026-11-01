# Upstream/main integration into multicore-support

Status: **PASS (merged and validated locally)**. Inputs: validated multicore feature
`f9f7a83bebcb4a3f4156f561a7adcdd74628c9ce` and main
`4ce065926c8096f34c77867c358f044ec1ea777e`, including official upstream
`89479dd09ce0ab37801505e61b277855eaeb8302`.

## Resolution and invariants

The merge conflicts in ten RTL files and two engineering documents.
Conflicting RTL hunks retain the feature's configurable harts, MHARTID
propagation, SCFail/HATOMIC sidebands, vector interrupt connections,
per-hart CLINT registers and 2*NCORES PLIC contexts. Automatic upstream
comment/format changes elsewhere are retained, together with its ordinary
single-core cleanup, Qmtech board support and new HPTW reserved-A/D test.
The CLINT/PLIC replacements continue to supersede upstream's single-hart
register implementations. No new protocol or datapath feature is introduced.
MSI/MESI/bursts remain optional; private I/D defaults remain 8 KiB; NCORES=1
retains coherence bypass. PMU support remains on its separate branch.

Raw conflict resolutions: `/tmp/wally-multicore-upstream-20261020/resolutions.json`.
All combined-source results below are from fresh models. The pre-merge Linux
baseline also took 347,795,562 cycles.

## Verification procedure and environment

Run `source ./setup.sh` first. This host uses Verilator 5.022 development
(`v5.020-157-g2b4852048`), RISC-V GCC 13.2.0 and Python 3.10.
`uv` is unavailable: invoke Python entrypoints directly; pre-commit uses
`PYTHONPATH=/tmp/wally-multicore-python`. Lint removes only the unsupported
`--quiet` argument, preserving the repository warning policy.

Working evidence: `/tmp/wally-multicore-upstream-20261020/`.
Local helpers use checked-in testbenches/runners and native `/tmp` outputs:

- `checks.py`: nine RV32/RV64 MSI/MESI controllers, 18,000 random operations,
  2/3/4 harts, one/two/four homes, mixed line geometry and optional paths.
- `legacy.py`: RV32/RV64 CLINT/PLIC, arbitration/reservations/AMO, shared
  cache and four line-transfer configurations.
- `soc.py`: sixteen matched 2/8 KiB full-core programs at RAM latency 0/3.
- `topology.py`: additional single-core, uncached, shared, MSI and MESI
  one/multiple-home full-core programs with up to four harts.
- `lint.py`: standard configurations, multi-hart/coherence configurations
  and structural checks that single-core bypass removes coherence modules.
- `directed.py`: ordinary RV64/RV32 MMU/PTE/fault/WFI/UART regression,
  including new hptwReservedAD and RV32 divflushstall32.

Assembly outputs must be outside this case-insensitive checkout: Make's
.S/.s intermediates otherwise alias source files. Directed ELF generation
uses separate preprocessing, assembly and link steps matching repository
recipes. The host's Verilator runtime lacks the emitted VL_SYSTEM_IN helper;
only generated model PCH files receive the compatibility wrapper before
C++ compilation. RTL/test assertions and verdicts are unchanged.

Fresh Linux used the unchanged, hash-verified 8 KiB software images, froze the
combined RTL/configuration/harness and built a new savable native model. The
100k continuous versus 50k+restore checkpoint states matched byte-for-byte. The
SMP run reached two CPUs online and shared atomic/protected counters 128/128,
then exited successfully after 347,795,562 cycles with no failure markers.
Model SHA-256: `7ffa5a7c1b4cb87e285ec1bab6d8a10ff73c22d6745050e676fb0059e203bd6a`.
Final log SHA-256: `f6eeff873465f5b42616d9eace9b0922ba45d501100aaf8c8f25119ade07d266`.
The model input manifest covers 235 sources. Regenerating ignored `config/deriv`
introduced only generation-time date comments in `multicore_linux/config.vh`;
its content matches the frozen model input after normalizing those comments.

## Current verdict and boundaries

Combined-source focused checks passed: nine controller models (18,000 random
operations), nine legacy peripheral/bus/shared-cache/line-engine checks, 41
full-core executions, 15 normal configuration lints, two FPGA configuration
lints, 20 ordinary directed RV32/RV64 tests and scoped pre-commit. The sixteen
matched cache-capacity cases retained their pre-merge cycle counts. The eleven
conflicted/adjacent RTL files retained the feature branch's non-comment tokens.
The merge commit is local; no push was requested. FPGA synthesis/timing, board
boot, arbitrary-N Linux, full ISA, nightly and lockstep remain unverified. Raw
artifacts are archived under `sim/verilator/wkdir/multicore/verification-
upstream-20261020/`; working scripts and logs also remain under `/tmp`.
