# Multicore maintenance and merge-readiness review

Status: **review completed; recommendations proposed, not implemented or accepted**.
Source: `multicore-support:0533e764dc43e6b6f418fb6189d38211b1c270d1`.
Baseline: local `main:4ce065926c8096f34c77867c358f044ec1ea777e`, which is
an ancestor of the reviewed source. This review did not merge branches or
change RTL. It evaluates the multicore delta, not every fork/upstream delta.

Implementation follow-up (separate source/result scopes): recommendation 1
is recorded in the [memory extraction](2026-10-21-memory-subsystem-extraction.md),
recommendation 2 in the [single-hart compatibility record](2026-10-21-singlecore-compatibility.md),
recommendation 3 in the [automated matrix record](2026-10-21-multicore-ci.md),
recommendation 4 in the [CPU/bus contract record](2026-10-21-core-bus-contract.md),
recommendation 5 in the [configuration/policy record](2026-10-21-multicore-configuration-policy.md),
and recommendation 6 in the [engine extraction record](2026-10-22-multicore-engine-extraction.md).
The findings below describe the reviewed revision; follow-up work does not
retroactively change that review or accept proposed ADRs.

## Scope and assessment

Configuration is partially orthogonal. Hart count and coherence options are
SoC parameters, separate from `cvw_t`; existing base config files, shared config
definitions and native `src/cache` implementation are unchanged against main.
However, the supported SMP profiles require disabling native I/D caches, private
memories, core bursts, and, for cached modes, Svadu/Svpbmt. MSI additionally
rejects cache-maintenance extensions. An arbitrary base configuration cannot
simply acquire more harts. These are explicit current capability restrictions.

Six new synthesizable modules contain 1,255 lines. Eleven existing RTL files
plus the lint wrapper change: 396 added/382 removed lines including formatting
and historical commented CLINT code. Within the CPU, seven files change
(`wallypipelinedcore`, `ebu`, `lsu`, `atomic`, `privileged`, `csr`, `csrm`):
43 additions/19 deletions when whitespace-only differences are ignored.
Core changes are mostly hart identity and an external reservation/atomic
sideband. The principal structural divergence is in SoC assembly and CLINT/PLIC.

Private caches are physical per-hart banks outside the native IFU/LSU caches.
One home has a central snooping controller; extra homes replicate that engine.
This limits invasive CPU changes, but is not a set of independent nonblocking
per-core L1 controllers. Each hart remains blocking. Scaling assumptions and
the single physical memory port must remain explicit.

## Findings and proposed priorities

1. **High: the legacy top owns the topology implementation.**
   `src/wally/wallypipelinedsoc.sv:30` exposes 15 additional parameters;
   lines 134-236 assemble bypass, arbitration, shared cache, MSI and banked
   coherence plus configuration checks. Extract the memory subsystem and
   its checks into a new module, leaving minimal wiring in the upstream top.
   Preserve the existing hart-zero probe path while changing this boundary.

2. **High: single-core bypass does not establish single-core equivalence.**
   CLINT/PLIC register logic is replaced even with NCORES=1. CLINT MSIP writes
   now honor byte strobes; PLIC address decoding also changes. In addition,
   `src/lsu/lsu.sv:411` changes BusAtomic from AtomicM to LSUAtomicM independently
   of SHARED_ATOMICS. The SoC also drives HCLK/HRESETn directly at lines 114-115;
   with P.BUS_SUPPORTED=0 the original core instead drove those outputs to zero.
   These may be desirable changes, but need separately scoped
   compatibility tests/changes. Compare old/new single-hart peripherals over
   defined accesses and make intentional differences explicit. Consider keeping
   upstream single-hart peripheral implementations behind adapters and placing
   multi-hart implementations in new modules; avoid duplicating the CPU itself.

3. **High: ordinary verification does not select multicore.**
   The checked-in GitHub workflows and regression-wally do not invoke the
   multicore runner. lint-wally, including its nightly derivative walk, supplies
   no NCORES override, so default elaboration remains single-core. Add an explicit
   automated matrix for default single-core and two/three-hart configurations,
   including atomic ordering, bus waits/errors and one/two homes. Keep longer
   Linux runs separate from a practical per-change suite.

4. **High: the CPU/bus boundary has implicit temporal assumptions.**
   `ahbmulticore.sv:2` documents ready-dependent busfsm issue. Write data and
   strobes remain live until the corresponding reply (lines 217-219), while
   address and HATOMIC are buffered. Define acceptance, address/data phases,
   sideband lifetime, AMO exclusion, sticky SC results and error/abort behavior
   as a stable contract. Add assertions and adapter-boundary tests. Existing
   observed Linux success does not prove compatibility with future busfsm changes.

5. **Medium: configuration and policy have multiple owners.**
   Parameter lists, option validation and capacities recur in the SoC, wrapper,
   hardware modules and Python builders/runners. RAM cacheability is independently
   decoded in four new RTL modules. The Linux DT generator hardcodes RV64 ISA,
   MMIO addresses and IRQ properties for its current platform. Introduce a separate
   multicore profile/configuration definition with one validation policy and
   explicit overrides; keep SoC topology out of the core's ISA configuration.
   Generate or check effective RTL/DTB/manifest consistency. Small stress-fixture
   cache defaults can remain intentionally different from deployment defaults.

6. **Medium: new modules still combine several responsibilities.**
   ahbmulticore combines port buffering, scheduling, LR/SC reservations, AMO
   locking, instruction banks and local-store notifications. ahbmsicache combines
   coherence control and array access. Isolate the reservation monitor, I-bank
   storage and common memory-policy definitions incrementally. Define RAM port
   and latency requirements before seeking FPGA BRAM inference: combinational
   array reads are present, but no new inference/resource result was measured.

7. **Explicit capability limits, not newly demonstrated regressions.**
   All writers must pass the coherent path; external DMA is not coherent.
   Bus HRESP recovery is not precise CPU error delivery; this is documented
   inherited EBU behavior, with additional writeback-error implications.
   FPGA multicore timing/boot and arbitrary hart counts remain unverified.
   Scope supported profiles accordingly; define error/DMA integration before
   claiming a general-purpose hardware coherence interface.

8. **Medium: documentation status needs reconciliation before publication.**
   ADR 0012 still says the 8 KiB default overlay is pending although source and
   the capacity experiment record the completed change. current-work also
   described the merge as unpublished although the reviewed local HEAD matches
   origin/multicore-support. Reconcile decision status explicitly with the user;
   a PASS record must not automatically convert proposed ADRs into accepted ones.

Recommended first tranche: isolate the SoC memory subsystem, specify the CPU
sideband contract, distinguish single-core fixes from multicore changes, and
automate compatibility/coherence checks. Further memory-array/controller
decomposition and hardware optimization can follow under the same regression
contract. This is a maintenance recommendation, not a newly observed protocol
failure or authorization to refactor.

## Newly executed evidence

Host: Verilator 5.036, setup.sh with RISCV=/home/aflores/riscv. From the root:

```bash
source ./setup.sh
make deriv
lint-wally
```

Seven standard lint configurations passed. Four additional XML elaborations
of wallywrapper passed with the normal RTL warning policy. Only the deprecation
diagnostic for the XML output option was disabled, before that option; bit
overrides use explicitly sized literals. No RTL warning category was disabled
beyond the repository lint policy. Exact commands and XML are in
`/tmp/cvw-multicore-review/<case>-command.txt` and `<case>.xml`.

| Case | P profile / options | Elaborated new memory-subsystem instances |
| --- | --- | --- |
| single-default | rv64gc, defaults | None |
| single-unused-options | rv64gc, NCORES=1, private I/D, MESI, two homes, bursts, forwarding and local paths requested | None |
| dual-msi | multicore_msi, NCORES=2, private D | One ahbmulticore and one ahbmsicache |
| dual-mesi-banked | multicore_msi, two harts/homes, private I/D, MESI, 4-word I/D lines, bursts, forwarding and local paths | One fabric, two arbiters, two MSI caches, two burst engines and one burst mux |

Standard lint log: `/tmp/cvw-multicore-review-lint.log`, SHA-256
`68fca2bbfbc9ee36c815059771d4755d59198e6000ff30ed3c87db23318557a6`.
Single-default count report SHA-256:
`0e733f7e5e5c864d317b7092150f4fcef4cf2bab3f0a879830225ae5882d4018`.
The single-unused-options count report has the same hash.
Dual-MSI count report SHA-256:
`a46cfc64153c5065938308882e90243f594ab6abd63161429e621f31a9300250`.
Dual-MESI/banked count report SHA-256:
`cbfc3109ecf446a94813a8817fc120f10ef14a2cdb932cef485d9acd88e259f6`.

These checks establish elaboration and structural bypass, not equivalence,
functional simulation, formal protocol proof, synthesized area or board behavior.
No new Linux simulation, synthesis, bitstream or hardware test was performed.
Earlier functional evidence remains scoped to its recorded revisions and tools.
