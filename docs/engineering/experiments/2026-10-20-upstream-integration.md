# Upstream integration through 89479dd09

Date: 2026-10-20. Result: **PASS for the focused checks below**.
Inputs: fork `main` at `5ce564236` (hardware boot documentation over
`82d0b80f7`) and official upstream
`89479dd09ce0ab37801505e61b277855eaeb8302` from
`https://github.com/openhwgroup/cvw.git`.
Integrated all 19 upstream-exclusive commits, including merges: PRs #1952
(RTL comments/format/unused-module cleanup), #1993 (`hptwReservedAD` test),
and #1601 (Qmtech Kintex-7 support).

## Merge resolution

`git merge --no-ff --no-commit upstream/main` conflicted in
`fpga/generator/Makefile` and `fpga/generator/wally.tcl`. Both board flows
were retained: Nexys Video at 20 MHz and the new Qmtech K7 at 32 MHz, with
separate targets, IP prerequisites, top-module branches and constraints.
Nexys Video retains `NEXYS_VIDEO`, its board repository override, DDR3/MMCM,
small ILA and `Performance_Explore`. Existing RAM/ROM depth casts from the
previous integration remain. No additional datapath changes were made.

The pre-existing `addins/vivado-boards` checkout at `36f34ab68`, different
from the superproject gitlink, was preserved and not staged. The bootloader,
bitstream, UART evidence, container configuration and other feature branches
were not replaced.

## Executed validation

After `source ./setup.sh`, the selected tools were Verilator 5.036 and
RISC-V GCC 15.2.0. Python entrypoints were invoked with `.venv/bin/python`.
Unlike the earlier integration host, this environment required no simulator
compatibility patches or disabled lint warnings.

| Check | Observed result |
| --- | --- |
| `make deriv` | PASS; generated both FPGA configurations |
| `bin/lint-wally` | PASS: rv32e, rv64gc, rv32gc, rv32imc, rv32i, rv64i, fdqh_rv64gc |
| Same `lint_config` function, fpganexysvideo and fpgaqmtechk7 | PASS |
| Verilator rv64gc, 14 ELFs listed below | PASS, including new hptwReservedAD |
| Verilator rv32gc, ramtop32 and divflushstall32 | PASS |
| `pre_commit run --all-files --show-diff-on-failure` | PASS |
| `make -n -C fpga/generator nexysvideo` and `qmtechk7` | PASS recipe expansion only; no Vivado run |

Simulation reproduction from the root:

```bash
source ./setup.sh
tests64='hptwReservedAD ramtop noncanonical paUpperBits tlbADdup tlbOverlap spillfaultdefer spillbothhalvesfault fpADUpdate wfiStallWake wfiTW wfiBackToBack svinvalfence uartLSRerr'
elfs64=()
for test in $tests64; do
    make -C tests/coverage "$test.elf"
    elfs64+=("tests/coverage/$test.elf")
done
JOBS=4 .venv/bin/python bin/wsim rv64gc "${elfs64[@]}" --sim verilator --name upstream-20261020
make -C tests/coverage32 ramtop32.elf divflushstall32.elf
JOBS=4 .venv/bin/python bin/wsim rv32gc tests/coverage32/ramtop32.elf tests/coverage32/divflushstall32.elf --sim verilator --name upstream-20261020-rv32
```

Both simulation runs printed `SUCCESS! All tests ran without failures.` and
returned exit 0. This is a focused regression, not full ISA, nightly,
functional-coverage closure or lockstep validation. FPGA configuration lint
does not elaborate the vendor-specific board top or establish hardware timing.

## Evidence and boundaries

Host-local evidence: `/datos/cvw-artifacts/upstream-integration-20261020/`:
`deriv.log`, `lint.log`, `lint-fpga.log`, test-build and simulation logs,
`pre-commit.log`, board recipe dry runs, `input-hashes.json` and
`merged-source.patch`. Raw generated models are under
`sim/verilator/wkdir/{rv64gc,rv32gc}_testbench/`.

Before adding this result documentation, the merged source index tree was
`d3a229332f2e7d9683bf73a185cbfd221f5cfe49`.
The patch from the fork input has SHA-256
`e6b04631871fb69cf7470e812c9564597296c9e2207215db399e1e386bd73864`.
The manifest hashes tested RTL, configuration, testbench and ELF inputs.
Evidence is local, not a remote archive.

No new Vivado synthesis, bitstream generation, programming or hardware Linux
boot was performed for this merge. The successful
[Nexys Video boot](2026-10-20-nexysvideo-vivado.md) remains evidence for
`82d0b80f7`, not the newly merged revision. Qmtech hardware and the separate
multicore/open-FPGA branches were not validated.
