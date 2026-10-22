# Multicore Actions ELF-conversion prerequisite fix

Source: `multicore-support:af35521ac` plus the workflow/documentation fix.
Status: **PASS for the local focused checks; remote rerun pending**.

## Observed failure

[GitHub Actions run 39751507533](https://github.com/antoniofloresgil/cvw/actions/runs/39751507533)
failed only `single-default`; bus, MSI and MESI/banked passed. Its uploaded
`multicore-single-default` artifact shows peripheral and clock checks passing.
`compatibility/atomic-walker/cached-run.log` then reports
`/usr/bin/env: ‘uv’: No such file or directory` when testbench/Makefile calls
bin/elf2hex. No ELF memory/label inputs are available to the simulation;
the subsequent missing AMO/walker overlap assertion is a consequence, not
observed evidence of an RTL regression.

The workflow installed pre-commit in an isolated environment but neither
installed uv nor exposed that environment to later steps. Install both tools
there and append its bin directory to GITHUB_PATH. No RTL or test acceptance
criteria change. Keep the normal elf2hex shebang and testbench conversion path.

## Focused validation

- `actionlint .github/workflows/multicore.yml`: PASS.
- Created a fresh Python venv and ran its `pip install pre-commit uv`, matching
  the workflow dependency step. Installed uv 0.13.5 and pre-commit 4.7.0.
- With PATH restricted to repository bin, the new venv/bin, /usr/bin and /bin,
  compiled amoADUpdate.S with system RISC-V GCC 14.2.0 and binutils. Ran the
  previously built Verilator 5.036 ordinary-testbench AMO/walker model twice:
  forced-uncacheable and +CACHEABLE_DATA. Removed generated memory/label files
  between runs to require fresh conversion in both. Both simulations PASS,
  including observed AMO/walker overlap and program self-checks.
- Scoped pre-commit and git diff --check: PASS.

Reproduction: source setup.sh; create a venv, install pre-commit and uv,
expose venv/bin on PATH, then run `python3 tests/multicore/ci.py --case single-default`.
The local check above reused the model from the preceding recommendation-7
matrix; no new model build, complete matrix or remote rerun is claimed.

Local logs/ELF inputs: `sim/verilator/wkdir/multicore-actions-uv-fix/`.
Downloaded failure logs: `/tmp/cvw-actions-single-default/` (temporary locator).
SHA-256 evidence:

- Remote failing simulation log: `9157a2dde026c5815bbb5e629465468270a2e40cfdc8d7c7d7a2704a915e6144`.
- Reused testbench model: `2490b77694f504d08601e0f739287e5babe253f433a9a50d5488b94ec70b85bc`.
- Uncacheable corrected-PATH simulation: `548c6a3ab573032e5a7f9040676fa735fd61d753d711d21655de987cec4145c8`.
- Cacheable corrected-PATH simulation: `74d8418bd7a4c9091061f59776ee1669360f3fc5ce2f3399b3b41a235b94627e`.
