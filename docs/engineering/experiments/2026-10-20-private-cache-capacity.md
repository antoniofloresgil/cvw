# Private-cache capacity comparison

Branch: multicore-support. Both 2 KiB frozen burst/MSI and MESI Linux baselines
passed before the private defaults were changed to 8 KiB per I/D cache per hart.
See ADR 0012. Raw evidence: sim/verilator/wkdir/multicore/verification-default8k-20261020/.
Commands and input hashes are in per-case JSON; Linux has independent frozen
sources, image/model/log hashes and byte-identical checkpoint validation.
All full-core comparisons use RV64, two harts, two coherence homes, MESI,
32-byte I/D lines, private I, local reads/writes, forwarding and bursts.
Only I/D capacity changes within each pair; RAM latency is explicitly shown.
Small-cache controller regression (nine models, 18,000 random operations) and
15 lint/structural checks pass after the default change. No synthesis/FPGA
area, BRAM inference or frequency claim follows from these simulation cycles.

| RAM wait | Program | 2 KiB cycles | 8 KiB cycles | Cycle reduction | 2 KiB RAM beats | 8 KiB RAM beats |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 0 | atomic | 14,707 | 14,144 | 3.83% | 1,156 | 1,056 |
| 0 | smoke | 2,106 | 2,074 | 1.52% | 186 | 186 |
| 0 | uart | 7,549 | 7,549 | 0.00% | 321 | 321 |
| 0 | exclusive | 3,244 | 3,227 | 0.52% | 304 | 300 |
| 3 | atomic | 17,839 | 17,144 | 3.90% | 1,116 | 1,036 |
| 3 | smoke | 2,375 | 2,395 | -0.84% | 190 | 190 |
| 3 | uart | 7,785 | 7,785 | 0.00% | 325 | 325 |
| 3 | exclusive | 3,739 | 3,702 | 0.99% | 304 | 300 |

Linux RTL SMP PASS with 8 KiB at 347,795,562 cycles; matching 2 KiB MESI
baseline: 388,367,974 cycles, cycle reduction 10.45%.
Both report two CPUs and counter=128/protected=128. New model SHA-256:
`f67668bfa6b4f2f9a16ed095c0158affbd5ac5230904a59f7a63f4f19433d8cf`. Log SHA-256:
`f6eeff873465f5b42616d9eace9b0922ba45d501100aaf8c8f25119ade07d266`. Kernel/SBI/init binaries are unchanged; only
DTB cache geometry and its RAM-image copy change. Metadata identifies both.
