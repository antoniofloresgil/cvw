# Cache-to-cache MSI supply

Date: 2026-10-20. Branch `multicore-support`; parent `f9bd2003f53197268e306f997026956fcf7111a3`
plus the change in this record's commit. Decision: [ADR 0008](../decisions/0008-cache-to-cache-supply.md).

## Question, sources and tools

Can the modified owner supply its requester without a redundant RAM reread,
preserving MSI, byte stores, full-line ownership, LR/SC and AMO ordering?
The implementation was prepared in isolation while the 32-byte baseline ran;
it is applied only after that baseline's verified PASS and origin publication.
The applied RTL/test/config inputs are byte-checked against the tested
candidate. `source-manifest.json` and `code-manifest.json` in the evidence
archive pin exact inputs and parent revision. Tools: Verilator 5.022 development
build, GNU C++ host toolchain, RISC-V toolchain selected by root setup.sh.
Linux/OpenSBI/compiler versions are recorded in the preserved image manifest.

## Executed focused results

PASS: 16 controller cases (RV32/RV64, 2/3 harts, latency 0/3, unequal
I/D lines, independent local-hit enables), each with 2,000 random operations.
PASS: 30 full-core atomic/smoke/UART runs with forwarding enabled, and three
fresh disabled-baseline runs. PASS: 20 lint/structural checks, including
single-core coherence elimination; four legacy checks; two negative controls.
Negative controls deliberately corrupt a non-requested line word or retain
the former M owner; the directed scoreboards reject both. DTS geometry,
manifest mismatch rejection and CLI guards also pass.

At equal 2 KiB I/D capacities per hart, two RV64 harts, latency 3 and 32-byte
I/D lines, atomic decreases from **19,179 to 14,147 cycles** (26.24% fewer),
smoke from 2,202 to 2,118, UART stays 7,571. Baseline defaults stay one word.
These are short-workload observations, not a universal performance claim.

## Reproduction and evidence

From the repository root after `source ./setup.sh`:

```bash
python3 tests/multicore/run.py --cores 2 --latency 3 --suite atomic --private-dcache --private-icache --local-dcache-reads --local-dcache-writes --cache-to-cache --cache-line-words 4 --icache-line-words 4 --work-dir /tmp/reproduce-c2c
python3 linux/smp/build.py --buildroot /path/to/buildroot --work /tmp/reproduce-c2c-linux --cores 2 --cache-mode msi --private-icache --local-dcache-reads --local-dcache-writes --cache-to-cache --cache-line-words 4 --icache-line-words 4
python3 linux/smp/run.py --work /tmp/wally-linux-c2c-20261020 --cache-to-cache --reuse --resume --checkpoint /tmp/wally-linux-c2c-20261020/resume.checkpoint --checkpoint-interval 5000000 --cycles 1500000000
```

Focused helpers and their exact commands, JSON verdicts, logs and binary
identities are preserved in `sim/verilator/wkdir/multicore/verification-c2c-20261020/`
and `/tmp/wally-c2c-preparation/`. Linux work is
`/tmp/wally-linux-c2c-20261020/`, with frozen sources, image manifest, model
metadata, QEMU result, checkpoint comparison and full-run output. The
`chain-status.json` in the preparation directory records actual progress;
a queued command does not establish PASS.

## Full Linux RTL

**PASS at 288,425,528 cycles**, exit 0: new two-hart model, MSI, private I/D banks of 256 RV64 words,
four words per line, all local-hit options and CACHE_TO_CACHE enabled.
RAM_LATENCY=0 models on-chip simulation memory, not external DDR3. The
previous model's Linux PASS does not validate this implementation. Publication
is conditional on QEMU PASS, bit-exact 100k versus 50k+restore checkpoints,
then full Linux PASS/exit 0, two CPUs and shared/protected counters 128.

## Limits

One global coherence transaction remains. M-to-M transfers avoid target RAM
traffic; M-to-S retains mandatory memory writeback to preserve clean S. No
burst, Owned state, external DMA coherence, arbitrary-N proof, precise fault
delivery or FPGA/DDR3 validation is claimed.

Final log SHA-256: `4a749e1c152b161c3529d3af67c7e708d238d9c164f10b45c88cbe660c7ac08b`. Model SHA-256: `48e1739b43f7942b01ba1450cf14136a006a6e2160be3f3ffeeadcbca4d165a0`.
Both online CPUs and both counters (128) verified. QEMU and exact checkpoint
restoration PASS. Final artifacts are in the evidence archive above.
