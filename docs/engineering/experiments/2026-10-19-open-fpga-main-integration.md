# Main integration into the open FPGA branch

Date: 2026-10-19. Result: **PASS for the focused checks below**;
physical implementation **NOT RUN**, DDR3 hardware retest **BLOCKED**.
Inputs: `opensource-fpga-bitstream:23ba9c2a7511988e5bc954134505ac48d8777b35`
and `main:82d0b80f7d1471f224fc5a8fc307d75f5eb26f53`, which contains official
upstream `712ee9719467e9e9987cebd55926ae8e01b08770`.
There were 225 main-exclusive reachable commits, including merges, relative
to this older feature tip. The resulting merge has these two branch inputs
as parents; use `git log --merges` for its identity.

## Integration and review

`git merge --no-commit --no-ff main` conflicted in README.md and
`bin/wally-package-install.sh`. Resolution retains the open FPGA tool list,
removes the retired RISCOF entry, and combines FPGA dependencies with main's
Fedora support and version-conditional ncurses5/libtinfo5 handling. Fedora
now also selects boost-devel/eigen3-devel, matching the other RPM families.
The package check and installation paths both include FPGA_PACKAGES.

The derivative recipe, CSR counter masks, GPIO input tie-off, optional
32-bit ROM preload and the LiteDRAM generator/diagnostic wiring were
reviewed against both inputs. The feature's AHB/Wishbone bridge, generated
wrapper interface, reset gating, shared clock and UART ownership are retained.
No additional RTL edits were needed. This is integration, not a DDR fix.

Existing clean submodule checkouts already matched the merged pointers:
`addins/riscv-arch-test:9add8bc99047c6274812169ee204d91e548e3e0e` and
`addins/vivado-boards:d8d43ed9f3f7e367ee3de82782ed601d88305677`.
The two untracked retired addins directories were left untouched.
No multicore changes were merged; main itself remains unchanged.

## Executed checks

Tools: Verilator 5.022 development revision `v5.020-157-g2b4852048`, bare-metal
GCC 13.2.0, host G++ 11.4.0, Python 3.10.12, Ubuntu 22.04 under WSL2.
Setup and derivative generation used `source ./setup.sh` and `make deriv`.

| Check | Observed result |
| --- | --- |
| Configuration lint | PASS: rv32e, rv64gc, rv32gc, rv32imc, rv32i, rv64i, fdqh_rv64gc, fpgaopensource; upstream lint flags, only unsupported --quiet removed |
| RV64GC standard testbench, 15 ELFs | PASS: ramtop, noncanonical, paUpperBits, tlbADdup, tlbOverlap, spillfaultdefer, spillbothhalvesfault, fpADUpdate, wfiStallWake, wfiTW, wfiBackToBack, svinvalfence, uartLSRerr, WALLY-uart-01, WALLY-uart-timeout-01 |
| RV32GC standard testbench, 3 ELFs | PASS: ramtop32, WALLY-uart-01, WALLY-uart-timeout-01 |
| FPGA top interface elaboration | PASS with limitations below; LiteDRAM stub, no generated DDR implementation |
| Installer package-selection matrix | PASS: Ubuntu 22/24, Debian 12/13, Fedora, RHEL 9, SUSE 15.6/16; FPGA dependencies and conditional Vivado packages checked without installing anything |
| Script checks | PASS: bash -n on seven setup/installer/generator scripts; Python generator parsed without importing LiteX |
| Pre-commit | PASS on 23 branch-specific/merged files and the refreshed engineering documents |

Both standard RTL testbench runs ended with
`SUCCESS! All tests ran without failures.` and exit 0. The existing ELFs
from the main integration were reused; models were newly built from the
combined RTL. Input ELFs and hashes are preserved with this run's evidence.
No test verdicts were bypassed.

The FPGA port check extracts the actual `litedram_ddr` declaration from the
Python generator into a temporary empty module; it does not execute that
generator or emulate DDR. Three existing model warnings remain: UNDRIVEN
for the empty BUFGCTRL declaration, and SYNCASYNCNET for resetn and HRESETn.
DECLFILENAME is suppressed for the existing multi-module FPGA source;
UNDRIVEN is suppressed inside the temporary DDR stub only. Wno-fatal permits
the three recorded warnings, and a separate assertion checks that the warning
list is exactly those three with no errors. This result is not strict clean
lint of the full generated design, a reset-domain analysis or DDR validation.
The eight ordinary configuration lints did not disable extra warning classes.

## Host adaptations, artifacts and reproduction

- uv is absent; setup completes but cannot install its optional hook.
  Python runners and the existing temporary pre-commit installation were
  invoked directly. Setup/generator shell working copies with CRLF were
  converted to LF as required by the newly integrated .gitattributes;
  that normalization does not change their indexed source content.
- Native Linux `/tmp` holds C++ builds and directed-test inputs, avoiding the
  workspace's case-insensitive .S/.s collision. The external VL_SYSTEM_IN
  compatibility header and model make options are the same as in the
  [main integration record](2026-10-18-upstream-integration.md).
- The host Yosys lacks the Slang frontend. nextpnr-xilinx, its chip databases
  and the installed LiteX environment are absent. A full FPGA build was not
  attempted or counted as a passing check. No tools were installed for this
  integration.

Reproduction helpers, logs, input lists, tool/parent metadata and a source
SHA256 manifest are in `/tmp/wally-open-main-20261019/` and archived under
ignored `sim/verilator/wkdir/open-fpga-main-integration-20261019/`.
`lint.py` calls the repository's lint_config for the eight configurations;
`directed.py` builds the two models using sim/verilator/Makefile and runs
+ElfList inputs; `top-lint.py` and `packages.py` implement the bounded checks
above. `results.json` records verdicts and log hashes; `sources.json` records
the combined source/configuration hashes. These are local evidence locations,
not repository-contained or remote archives.

No board access was available. Firmware execution, BRAM inference, service-CPU
startup, DDR calibration/memory tests, Wally handoff and post-route timing
remain unverified on the combined revision. In particular, sys4x timing must
be checked independently; configuration/port lint does not constrain it.
The [unresolved DDR checkpoint](open-ddr3-bringup.md) remains authoritative
about the reported hardware failure. No Linux boot, full ISA/nightly,
lockstep, coverage closure or ASIC run was performed in this integration.
