# Multicore profiles and policy

`schema.json` owns public topology parameters, deployment defaults, named test/Linux
profiles and supported-combination rules. It does not add fields to `cvw_t`.
`profiles.py` resolves a profile plus explicit CLI overrides and evaluates the
same rule expressions that it translates into SystemVerilog. Regenerate after
editing the schema:

```bash
python3 config/multicore/profiles.py --generate
python3 config/multicore/profiles.py  # fail if the checked-in header is stale
```

The generated `config/shared/multicore-config.vh` defines `multicore_t`, the
validation function and the parameter/delegation macros used by the SoC, memory
subsystem and simulation/lint wrappers. The include lives in package `cvw` after
`cvw_t`; it is separate configuration data, not part of that core struct. Public
parameter names remain available for named instantiation and Verilator `-G`.
Module-local array/protocol assertions remain defensive checks for those modules'
standalone interfaces. The physical RAM allocation policy has one implementation
in `config/shared/multicore-memory.vh`, used by every optional cache/home engine.

The default private I/D capacities are 8 KiB each, expressed in AHB words and
resolved using AHBW. `stress` deliberately uses 256 words; `ci-msi` and
`ci-mesi-banked` use 32 words/four-word lines to force conflicts. These profiles
are not deployment capacity changes. Existing CLI flags override profile values;
boolean flags also have `--no-...` forms. For example:

```bash
source ./setup.sh
python3 tests/multicore/run.py --profile ci-msi --cores 2 3 --cache-words 64 --suite atomic
python3 linux/smp/build.py --profile linux-msi --cores 2 --buildroot /path/to/buildroot
```

`--cache-words` retains its meaning as the selected data/shared-cache capacity;
`--shared-cache-words` is also available in the generic runner. A simultaneous
explicit `--cache-words` selects the active shared capacity. Fixture-specific
hart/latency limits remain properties of the fixture, not universal RTL limits.

`tests/multicore/config_tb.sv` evaluates the selected config through the actual
SystemVerilog includes and emits the effective core fields and topology. Python
checks this report against the requested values; it does not parse localparams
or reproduce `config-shared.vh`. Linux DTS properties use this report for ISA,
MMU, RAM/MMIO windows, PLIC source count/UART IRQ and cache geometry. The Linux
recipe remains RV64/Sv39 with a fixed boot/image placement and a software-defined
clock; its limits are explicit in `linux_platform` and the builder checks them.
It is not a generic device-tree description for every Wally configuration.

Image manifests now record `effective_configuration` and policy version/hash.
The runner re-evaluates the RTL, checks manifest fields and artifact hashes,
regenerates the expected DTS, and compares the actual DTB to a fresh compilation
of that DTS before model build/reuse or execution. Old image manifests must be
regenerated; old models/checkpoints are not silently migrated. `dtc` and Verilator
are consequently required for the Linux configuration checks, including QEMU.

After setup and derivative generation:

```bash
python3 tests/multicore/check_profiles.py --work-dir /tmp/cvw-profile-check
```

This checks Python/SV rule parity, real RV32/RV64 defaults, RAM/MMIO boundaries,
Linux DT generation and stale RTL/manifest/DTS/DTB rejection. The single-default
CI case selects it automatically. The pre-commit hook checks header freshness.

## Capability and evidence scope

The schema also owns the optional subsystem's `capability_contract`. Inspect it
without building RTL (the report explicitly says core configuration is unchecked):

```bash
python3 config/multicore/profiles.py --describe --profile ci-msi
```

Effective SV reports add the canonical capability report after core/topology
constraint validation. This describes implementation availability and limits,
not execution or FPGA qualification. CI records actual execution scope separately.
Native bypass is outside the new buffered-hart ordering contract. The CLINT range
is addressability and Linux max_harts is an image-recipe bound; neither qualifies
arbitrary counts. External DMA coherence and precise CPU HRESP faults are
unsupported; multicore FPGA and arbitrary-count qualification are unverified.

A consumer can explicitly require a property; unavailable properties fail before
compilation, and every requested hart count is checked separately:

```bash
python3 tests/multicore/run.py --profile ci-msi --cores 2 3 --require-capability coherent_hart_ports
# Rejected before building: no external coherent ingress exists.
python3 tests/multicore/run.py --profile ci-msi --require-capability external_dma_coherence
```

Requirements do not enable hardware. Linux builders/runners use the same checks;
forged/stale capability metadata is rejected by DT generation. Schema version 2 adds capability-contract version 1 and requires regeneration of older image manifests. Experimental full-core
SoC/Linux simulations stop on bus HRESP outside reset; intentional error injection
belongs to transport/controller fixtures. See the
[capability and DMA/error integration contract](../../docs/engineering/interfaces/multicore-capabilities.md)
for current failure semantics and future acceptance criteria. Nothing here adds
coherent DMA, precise traps, writeback retry or a hardware qualification result.
