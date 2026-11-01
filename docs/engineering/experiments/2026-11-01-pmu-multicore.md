# PMU on multicore configurations

Date: 2026-11-01. Branch `adding-mpu-support`, commit `d0d11792c`, above the
merge of `main` `568a9ed65` (`c0a1fb4aa`). Merged into `main` by PR #25
(`da9e9c21c`).

Status: **PASS** in Verilator. FPGA timing and board operation of multicore PMU
configurations are not claimed.

## Question

Do the per-hart counters, Sscofpmf overflow interrupts and cache events work
when several harts share the multicore memory system?

## Finding and change

With the private multicore caches (`PRIVATE_DCACHE`, `PRIVATE_ICACHE`) the
core's own I$ and D$ are off, so events 13/14 (D$ access/miss) and 16/17 (I$
access/miss) stayed at zero. `multicore_memory_system` now reports per-hart
cache events through a new 4-bit `ExtCacheEvents` input of
`wallypipelinedcore`, ORed into the existing events:

- access: an accepted cacheable request of the hart (data or instruction by
  `HPROT[0]`);
- D$ miss: a cacheable data lookup in `ahbmsicache` that finds no line in the
  owner's bank (a permission upgrade of a present line counts as a hit);
- I$ miss: an instruction line fill started by `ahbmulticore`;
- with coherence banks, `ahbmsifabric` merges the per-hart misses of every home.

The input is zero without private caches, so single-core configurations are
unchanged. `wallypipelinedcore.sv` gains one port and `wallypipelinedsoc.sv`
connects it; the rest of the change is in `src/ebu/`.

## Test

`tests/multicore/pmu.S` runs the same image on every hart of the new
`multicore_pmu` derivative (`multicore_coherent` plus Sscofpmf, Smcntrpmf and
Smcdeleg):

1. every hart writes distinct values to `mhpmcounter19` and `minstret` while
   inhibited and reads back its own values after all harts have written;
2. all harts count CSR writes concurrently with different amounts of work;
   each counts exactly its own, and `minstret` agrees;
3. even harts overflow counter 19 with LCOFI enabled and take exactly one
   interrupt with OF set; odd harts count without overflowing and take none;
4. with private caches (`-DCACHE_EVENTS`), 16 loads from a hart-private region
   raise D$ accesses by at least 16 and D$ misses by at least one, and a call to
   code aligned to 256 bytes and never fetched before raises I$ accesses and I$
   misses.

`tests/multicore/run.py --suite pmu` builds and runs it; `tests/multicore/ci.py`
lints `multicore_pmu` with 2 and 3 harts and runs the suite in every multicore
profile except `single-default`.

## Results

| Check | Result |
|---|---|
| `pmu` suite, `ci-msi` and `ci-mesi-banked`, 2 and 3 harts, RAM latency 0 and 3 | 8/8 PASS (3796 to 7331 cycles) |
| Lint of `multicore_pmu`, `ci-msi`/`ci-mesi-banked`/`stress` topologies, 2 and 3 harts | PASS |
| `tests/pmu/run.py` (single-core CSR, event and interrupt checks, board DTBs) | 23/23 PASS |
| `regression-wally` (ACT rv32imc/rv32gc/rv64gc, periph, lint, buildroot, multicore matrix) | PASS |
| GitHub CI on PR #25 (lint, four multicore profiles) | PASS |

The full regression ran before the I$-miss check (step 4, last part) was added
to `pmu.S`; the `pmu` suite rows above include it.
