# Main integration into the open FPGA branch

Date: 2026-10-23. Inputs:

- `opensource-fpga-bitstream:f950a775310e7613d22f409bcaaec81f8a8a646e`.
- `main:1d567764895321b64a9b8e28d0b77ca4b9eb0aac`, including optional
  multicore support and official upstream `89479dd09`.
- Feature/main merge base `82d0b80f7`; official remote identified as
  `upstream`, URL `https://github.com/openhwgroup/cvw.git`. The pre-merge
  official-upstream merge base was `712ee9719`.

Result: **PASS for the focused combined-source checks below**.
This merge updates the feature branch; it does not merge the open FPGA flow
back into main. Physical implementation and hardware tests are **NOT RUN**.
The existing open-flow DDR3 failure remains unresolved.

## Integration and review

`git merge --no-ff --no-commit main` conflicted in `rom1p1r.sv` and three
engineering documents. The ROM resolution preserves this branch's existing
preload behavior for both 32-bit and 64-bit memories, retaining main's other
cleanup. The open FPGA wrapper, LiteDRAM generator, service-CPU diagnostics,
DDR-ready reset gating and AHB/Wishbone bridge are unchanged from the feature
parent. Existing GPIO input tie-off and counter-mask expressions remain.

Main's optional multicore memory subsystem, atomic sidebands, peripherals,
configuration policy and tests are imported without additional datapath or
public-interface changes. `fpgaOpenSource` continues to instantiate the SoC
with the default single-hart topology. This merge does not enable a coherent
multicore FPGA build or add a DDR initialization path using Wally.

The Makefile auto-merge retains open/Vivado selection and the new Qmtech K7
target. Configuration generation retains `fpgaopensource` alongside main's
multicore derivatives. Task changes were reviewed against the feature parent;
the cumulative feature diff was reviewed against `main:1d5677648` and the
identified official upstream `89479dd09`. Existing differences in upstream
RTL remain limited to ROM preload, counter masks, GPIO tie-off and the added
AHB/Wishbone bridge relative to main; the wider multicore changes are inherited
from main, not a new refactor in this merge.

Engineering index, architecture notes and current checkpoint now distinguish
the combined branch from the historical multicore and Vivado hardware results.
Submodules were not updated. Their checkouts matched the recorded gitlinks:
arch-test `9add8bc99`, Vivado boards `d8d43ed9f`.

## Executed validation

Tools selected after `source ./setup.sh`: Verilator 5.036, RISC-V GCC 15.2.0.

| Check | Observed result |
| --- | --- |
| `make deriv` | PASS |
| `uv run --script bin/lint-wally` | PASS, seven standard configurations |
| Same `lint_config`, `fpgaopensource` | PASS |
| Standard rv64gc testbench | PASS: hptwReservedAD, amoADUpdate, ramtop, fpADUpdate, tlbADdup |
| ROM conflict check | PASS: 32/64-bit preload, disabled 32-bit preload and CE-low output hold |
| FPGA wrapper interface lint | PASS within the stub limitations below |
| Nexys Video Makefile recipes, `FLOW=opensource` and `FLOW=vivado` | PASS dry-run selection only |
| Seven open-flow installer/setup/generator shell scripts | PASS `bash -n` |
| LiteDRAM Python generator | PASS AST parse, without generation |
| `uv run pre-commit run --all-files --show-diff-on-failure` | PASS |
| `tests/multicore/ci.py --case all` | PASS: single-default, bus, MSI, banked MESI and feature interactions |

The aggregate CI returned exit 0 and printed
`SUCCESS! Multicore CI matrix passed`. All four profiles and the complementary
feature-interaction suite report PASS. Its recorded source hashes were
checked against the final combined sources without mismatches. The standard
five-ELF simulation also returned exit 0 with
`SUCCESS! All tests ran without failures.`

Core reproduction commands from the repository root:

```bash
source ./setup.sh
make deriv
uv run --script bin/lint-wally
python3 tests/multicore/ci.py --case all --skip-deriv \
    --work-dir /datos/cvw-artifacts/open-fpga-main-20261023/multicore-ci
make -C tests/coverage hptwReservedAD.elf amoADUpdate.elf ramtop.elf fpADUpdate.elf tlbADdup.elf
JOBS=4 uv run --script bin/wsim rv64gc tests/coverage/hptwReservedAD.elf \
    tests/coverage/amoADUpdate.elf tests/coverage/ramtop.elf \
    tests/coverage/fpADUpdate.elf tests/coverage/tlbADdup.elf \
    --sim verilator --name open-main-20261023
```

The top check extracts only `litedram_ddr`'s actual port declaration from
`gen_litedram.py` into an empty temporary module, then lints `fpgaOpenSource`
with the combined RTL/configuration. The check requires exactly the three
known warnings: undriven empty BUFGCTRL output and mixed synchronous/asynchronous
use of resetn/HRESETn. It suppresses UNDRIVEN inside the temporary DDR stub,
and DECLFILENAME for the existing multi-module wrapper. `-Wno-fatal` permits
only those expected warnings; the driver rejects any different warning list
or errors. No generated DDR controller, service CPU or firmware is simulated.

The ROM fixture reads known memory words beyond address zero, checks both
widths and preload-disabled output, and verifies CE-low retention. It uses
the unchanged getenv DPI helper with its generated header name adapted to the
fixture top. An initial fixture build used the ordinary testbench header and
failed; correcting that external helper required no repository source change.

## Evidence and scope

Host-local evidence directory:
`/datos/cvw-artifacts/open-fpga-main-20261023/`. Logs include `lint.log`,
`lint-open.log`, `directed.log`, `multicore-ci.log`, `top-lint.log`,
`rom-build.log`, `rom-run.log`, pre-commit and Makefile dry runs. The directory
also preserves `check-open.py`, the external ROM fixture/DPI helper and test
data, `branch-input-hashes.json`, parent IDs and before/after/task/cumulative
patches. Multicore CI produces its own source manifest and verdict reports.
This evidence is local, not a repository-contained or remote archive.

Successful RTL and stub-interface checks do not establish DDR calibration,
service-CPU firmware execution, memory stress, Wally handoff or routed timing.
No Linux SMP run, new Vivado/open bitstream, board programming, full ACT,
nightly, lockstep or coverage-closure run was performed for this integration.
Installed FPGA tools were inspected, but no physical build was attempted.
The earlier Vivado Linux boot at `82d0b80f7` is not a verdict for this merge
or the open LiteDRAM implementation.
