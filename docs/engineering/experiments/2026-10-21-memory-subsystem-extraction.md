# Multicore memory subsystem extraction

Status: **PASS (focused checks and fresh native RTL Linux SMP)**.
Branch/source: `multicore-support`, parent `ce02cf1ad`; the accompanying
implementation is identified by `source-hashes.json` in the evidence directory.
This implements recommendation 1 of the
[maintenance review](2026-10-21-multicore-maintainability-review.md), following
[ADR 0013](../decisions/0013-multicore-memory-subsystem-boundary.md).

## Question and change

Can memory topology be removed from the upstream SoC assembly without
changing observable behavior on the existing feature branch?

`multicore_memory_system` owns the former SoC-local bus/cache wiring,
generate branches and capability assertions. Its topology/assertion body is
byte-identical to the parent's body. Existing public parameters, clock/reset
ownership, hart and uncore hierarchy are preserved. Only memory-internal
white-box testbench paths acquire `memory_system`. The original SoC shrinks from 251 to 154 lines. No CPU, peripheral,
coherence engine or configuration RTL was modified.

## Environment and reproduction

Host: Verilator 5.036, Python 3.14, bare-metal RISC-V GCC 15.2.0, setup.sh selecting
`RISCV=/home/aflores/riscv`. No old-host Verilator adaptations were required.
Working evidence: `/tmp/cvw-memory-extraction/`; Linux products:
`/tmp/cvw-memory-extraction-linux/`. Selected raw evidence is archived in
`sim/verilator/wkdir/multicore/verification-extraction-20261021/`, including
helper scripts, exact command arrays, baseline snapshots, comparison logs,
source/image hashes, XML, Linux model metadata/binary and final verdict.
`artifact-hashes.json` inventories the archive. Raw logs and generated products
are not permanent documentation.

```bash
source ./setup.sh
make deriv
lint-wally
python3 /tmp/cvw-memory-extraction/structure.py
python3 /tmp/cvw-memory-extraction/rv32-lint.py
python3 /tmp/cvw-memory-extraction/compare.py
wsim rv64gc tests/coverage/fpADUpdate.elf tests/coverage/hptwReservedAD.elf tests/coverage/ramtop.elf tests/coverage/wfiBackToBack.elf tests/coverage/uartLSRerr.elf --sim verilator
wsim rv32gc tests/coverage32/divflushstall32.elf tests/coverage32/ramtop32.elf --sim verilator
```

The evidence helpers save exact compiler command arrays. `compare.py` uses
the checked-in full-core testbench, DPI, assembly, linker and image builder.
It obtains the old SoC and old probe paths from verified copies of
`git show ce02cf1ad:<path>` and compiles both implementations with the same
other sources. Its only added observer computes a rolling 64-bit digest over
all hart request/response vectors, atomic sidebands and uncore bus signals on
every non-reset rising edge. It compares PASS/cycle counts, memory/local
traffic, UART writes and digests. This is sampled simulation evidence, not a
formal equivalence proof; a digest is not a retained complete waveform.

| Profile | Harts | RAM latency | Memory options | Programs |
| --- | --- | --- | --- | --- |
| single | 1 | 0 | uncached | smoke, atomic, uart |
| single-unused | 1 | 3 | all private options requested, two homes; bypass effective | smoke, atomic, uart, exclusive |
| dual-bus | 2 | 0 | uncached | smoke, atomic, uart |
| triple-bus | 3 | 3 | uncached | smoke, atomic, uart |
| single-shared | 1 | 3 | shared cache | smoke, atomic, uart |
| dual-shared | 2 | 0 | shared cache | smoke, atomic, uart |
| triple-shared | 3 | 3 | shared cache | smoke, atomic, uart |
| dual-msi | 2 | 0 | private D, one-word lines | smoke, atomic, uart |
| triple-msi | 3 | 3 | private D, one-word lines | smoke, atomic, uart |
| dual-mesi | 2 | 3 | all private options, one home | smoke, atomic, uart, exclusive |
| dual-banked | 2 | 0 | all private options, two homes | smoke, atomic, uart, exclusive |
| triple-banked | 3 | 3 | all private options, two homes | smoke, atomic, uart, exclusive |

Private test capacities are 256 AHB words per I/D cache. All-private profiles
use private I/D, MESI, forwarding, line bursts, local reads/writes and
four-word I/D lines. Uncached uses `multicore_atomic`, shared uses
`multicore_coherent`, private uses `multicore_msi` derivatives. The SoC's
8 KiB deployment defaults remain unchanged.

Generate derivative configs before these tests. Do not concurrently invoke
another `derivgen.pl`: it deletes/recreates the directory. An initial helper
run overlapped Linux model preparation and hit a missing generated config;
the complete matrix passed after serialization. The initial RV32 exploratory
fixture used an inconsistent rv32gc cache-disabled overlay and produced an
LSU upper-bit warning; the final RV32 checks use the integer rv32i profile
and a correctly named wrapper without disabling warning categories.

## Completed focused results

- Seven ordinary configuration lints passed without errors or warnings.
- Four structural elaborations passed using the repository lint warning
  policy (only the XML option's deprecation notice is additionally disabled).
  Single-core default and unused-private-option cases contain none of the six
  optional memory engines. Dual MSI contains one arbiter/cache; dual MESI with
  two homes contains two arbiters/caches/burst engines, one fabric and one mux.
- Two additional RV32 integration lints passed: three harts, one/two homes,
  all private options, four-word I/D lines. The temporary rv32i-based fixture
  disables private memories/native caches/core bursts and unsupported cache
  maintenance/PTE attributes to satisfy the existing SMP restrictions.
- **40 before/after comparisons passed (80 full-core executions)** with
  identical cycle counts, traffic counts and bus digests.
- Scoped pre-commit and updated documentation links passed.
- Seven ordinary RV64/RV32 directed ELFs passed with the normal testbench and
  native base-cache configurations; the preserved `dut.core`/uncore probe
  paths work in this flow.

## Fresh Linux SMP

```bash
source ./setup.sh
python3 linux/smp/build.py --buildroot /home/aflores/riscv/buildroot --work /tmp/cvw-memory-extraction-linux --cores 2 --cache-mode msi --cache-words 1024 --icache-words 1024 --private-icache --local-dcache-reads --local-dcache-writes --cache-to-cache --cache-bursts --mesi --coherence-banks 2 --cache-line-words 4 --icache-line-words 4 --jobs 4
python3 linux/smp/run.py --work /tmp/cvw-memory-extraction-linux --jobs 3
```

New Linux 6.19.14/OpenSBI 1.7 images and a fresh native savable RTL model were
built from the extracted implementation. Two harts, two homes, 8 KiB private
I/D per hart, 32-byte I/D lines, MESI, bursts, forwarding and local read/write
paths. No old checkpoint was restored. **PASS after 339,802,249 cycles**:
`WALLY_SMP_ONLINE cpus=2 expected=2` followed by
`WALLY_SMP_PASS cpus=2 counter=128 protected=128`, exit code 0.
All 236 frozen model source/configuration/harness hashes matched the working
tree after execution. New software images differ from the historical Linux
experiment; its cycle count is not a before/after performance comparison.

## Evidence hashes

SHA-256 of the Linux model:
`f95836cb367730bba2996407d9b4b857f3813270bcc4851b6221c7e62ecbc0a2`.
Final Linux log:
`042eb2875fb98545a299172ea7dbd010cb8070af15078cdfd9b35bea4c78fa8f`.
Comparison result JSON:
`6941b6a7834f2f4f732d34049631a2d3c8437f3c62b3e60af7bec19f5c23d28d`.
Source identity is recorded in `source-hashes.json`; native directed ELF hashes
are in `native-elf-hashes.json`. The Linux manifest and rtl-result.json record
image/configuration hashes and the selected topology.

## Boundaries

These comparisons are against the feature parent, not upstream main. They do
not resolve the review's other peripheral/atomic differences or establish
formal equivalence, exhaustive ISA verification, arbitrary-N Linux, FPGA
synthesis/timing or hardware boot. Historical Linux results remain scoped to
their original sources. Other review recommendations and ADR statuses are
unchanged.
