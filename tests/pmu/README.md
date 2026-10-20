# PMU checks

After sourcing setup.sh, run `python3 tests/pmu/run.py --work /tmp/pmu-unit`.
The six directed Verilator configurations cover RV32/RV64 and COUNTERS=3/8/32,
including permissions, fixed event sources, retirement gating, enable/inhibit
and rollover. The same command checks the generated OpenSBI mapping and all
real board DTBs. Full-core coverage uses tests/coverage/hpmcounters.S.
Linux/OpenSBI and actual perf stat integration are documented in
[linux/pmu](../../linux/pmu/README.md). Counter RTL is synthesizable; these
fixtures are simulation verification, not a synthesized-board verdict.
