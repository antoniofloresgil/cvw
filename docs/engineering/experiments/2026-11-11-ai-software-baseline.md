# Software baseline for the AI unit: cycles per int8 MAC

Status: **measured on 2026-11-11 in the RTL simulation of the chip** (`make chipsim`, test `ai_baseline`). Step 0 of
[ADR 0024](../decisions/0024-edge-ai-accelerator.md). The same image has not been run on the Nexys Video yet; the simulation is
the chip's RTL with the IHP SRAM models, so the cycle counts should match, but the board run is pending.

## What was run

`asic/librelane/chip/ai/baseline/`: plain C, `-O2`, `rv32imac_zicsr`, loaded at 0x80000000, counters `mcycle` and `minstret`.
Four dot-product kernels over 256 int8 pairs (16 calls each, results must agree), then a 64 x 64 fully connected layer (bias,
fixed-point requantization, clamp, ReLU) on the naive and on the best word kernel.

## Results

| Kernel | cycles/call | cycles/MAC | instr/MAC | IPC |
|---|---|---|---|---|
| naive (`a[i]*b[i]`) | 7737 | 30.22 | 7.04 | 0.23 |
| unrolled by 4 | 6527 | **25.49** | 4.81 | 0.18 |
| 32-bit loads, shifts | 7868 | 30.73 | 7.05 | 0.22 |
| 32-bit loads, shifts, x2 | 7346 | 28.69 | 6.60 | 0.23 |
| layer 64 x 64, naive | 130033 | 31.74 | 7.40 | 0.23 |
| layer 64 x 64, word x2 | 126513 | 30.88 | 7.14 | 0.23 |

## What it says

- A MAC costs **25 to 32 cycles**, about 0.6 MMAC/s at 18.4375 MHz. A 64 x 64 layer takes about 6.9 ms.
- The IPC is 0.18 to 0.23: the core is **memory bound** (no caches on the chip, so every instruction fetch and data access
  goes over the bus to the RAM macros), not compute bound. Word loads and unrolling hardly help; the unroll by 4 wins
  only because it fetches fewer instructions per MAC.
- Consequence for the unit: the bus is the bottleneck, not the multipliers. The unit must hold operands in a local scratchpad
  and reuse them (weights stream once, activations stay), or its master will wait on the same RAM latency. The 147 MMAC/s
  ceiling of ADR 0024 (8 lanes) assumed one operand pair per lane per clock from local storage; a bus-fed design reaches
  only a fraction of it. Step 1 should measure the RAM's cycles per word on a burst before fixing the number of lanes.
- The bar for step 3: a layer well under 126 K cycles. Ten times fewer (about 12 K cycles) needs about 3 cycles per MAC.

## Reproduce

```bash
cd asic/librelane/chip/test
COCOTB_TEST_FILTER=ai_baseline IHP_PDK=<.../ihp-sg13g2> WORK=../../work/asic_soc_rv32imac \
  PATH=$HOME/riscv/oss-cad-suite/bin:$PATH tabbypy3 test_chip.py     # about 5 minutes with the Verilator build
# on the board: make -C asic/librelane/chip/ai/baseline && asic/librelane/chip/uart_load.py <FT232R> build/baseline.bin
```
