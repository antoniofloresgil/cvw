# Official upstream integration into main

Date: 2026-10-18. Result: **PASS for the focused checks below**.
Inputs: fork `50ad3a44a60bf939f8575a0538b847861dccd39b` and official
`https://github.com/openhwfoundation/cvw.git` main
`712ee9719467e9e9987cebd55926ae8e01b08770` (88 upstream-exclusive commits,
including merges). Identify the resulting merge with `git log --merges`.

## Integration and local adjustment

`git fetch <official-url> main` followed by
`git merge --no-ff --no-commit FETCH_HEAD` applied without conflicts.
The automatically combined Ubuntu package logic and derivative recipes were
reviewed. Fork Nexys Video support, container, line-ending rules and engineering
documentation remain. The clean `addins/vivado-boards` checkout was updated to
the merged pointer `d8d43ed9f3f7e367ee3de82782ed601d88305677`.
The two pre-existing untracked addins directories were left untouched.

Upstream's RAM/ROM depth calculation triggered WIDTHEXPAND with the installed
Verilator. In `ram_ahb.sv` and `rom_ahb.sv`, the denominator was changed from
`64'(P.XLEN/8)` to `(64'(P.XLEN)/8)`, converting XLEN before division. For the
supported XLEN values 32/64 this preserves the numerical depth. Strict lint
and both top-of-RAM tests passed after the adjustment.

## Executed checks

Tools: GCC 13.2.0; Verilator reports 5.022, development revision
`v5.020-157-g2b4852048`. Configuration generation used
`source ./setup.sh` and `perl bin/derivgen.pl`.

| Check | Observed result |
| --- | --- |
| Lint, same source/flags as `bin/lint-wally` except unsupported `--quiet` omitted | PASS: rv32e, rv64gc, rv32gc, rv32imc, rv32i, rv64i, fdqh_rv64gc; no warnings suppressed |
| rv64gc, 15 ELFs | PASS: ramtop, noncanonical, paUpperBits, tlbADdup, tlbOverlap, spillfaultdefer, spillbothhalvesfault, fpADUpdate, wfiStallWake, wfiTW, wfiBackToBack, svinvalfence, uartLSRerr, WALLY-uart-01, WALLY-uart-timeout-01 |
| rv32gc, 3 ELFs | PASS: ramtop32, WALLY-uart-01, WALLY-uart-timeout-01 |

Both actual RTL testbench runs ended with
`SUCCESS! All tests ran without failures.` and process exit 0. ELFs used the
repository's coverage/peripheral sources and linker scripts. These checks
exercise selected upstream fixes; they are not a full ISA, nightly, lockstep,
coverage-closure or Linux-boot regression. No FPGA or ASIC validation was run.
The multicore and open-FPGA branches were not merged or revalidated here.

## Host adaptations and reproduction evidence

- `uv` is absent. Setup completed without installing its optional hook;
  Python entrypoints and the existing temporary pre-commit installation were
  invoked directly. This is not a successful test of uv installation.
- The workspace is a case-insensitive Windows 9p mount. Coverage Makefiles
  use `.S` inputs and `.s` intermediates; their cleanup can remove the input
  on this filesystem. A failed initial build did so; affected source paths
  were restored from the merge index. Final inputs and build products used
  native Linux `/tmp`, with preprocessing, assembly and linking separated as
  in the Makefiles. GCC 13 does not parse Svinval in `-march`; the assembler
  accepts the coverage Makefile's ISA list.
- Models used `sim/verilator/Makefile` with explicit `WALLYCONF`,
  `TESTBENCH=testbench`, native `WORKDIR` and `JOBS=2`. Runtime used `+TEST=none`
  and `+ElfList=<prepared-list>`; memory/label metadata was generated with
  `python3 bin/elf2hex` and `bash bin/extractFunctionRadix.sh`.
- This installed Verilator emits `VL_SYSTEM_IN` for `$system(string)` but its
  runtime omits that helper. An external C++ header supplied
  `inline IData VL_SYSTEM_IN(const std::string& s) { return std::system(s.c_str()) >> 8; }`,
  matching its existing packed-string helper's exit status. Generated model
  make used `VK_PCH_I_FAST= VK_PCH_I_SLOW=` and
  `USER_CPPFLAGS='-include <compat-header>'`. RTL and verdict logic were not
  bypassed. A modern supported toolchain should use the normal runners;
  these runs do not establish that an unmodified runner works on this host.

Exact commands, helper/driver, logs and hashes are preserved in ignored
`sim/verilator/wkdir/upstream-integration-20261018/`; native build products
are in `/tmp/wally-upstream-integration/`. These are local, not remote archives.
