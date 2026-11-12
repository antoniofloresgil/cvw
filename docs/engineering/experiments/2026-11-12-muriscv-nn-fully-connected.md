# muRISCV-NN fully connected layer on the chip (scalar C)

Status: **measured on the Nexys Video on 2026-11-12** (chip `asic_soc_rv32imac_ai`, bitstreams of both flows, the unit not used). Part of the
reference for step 3 of [ADR 0024](../decisions/0024-edge-ai-accelerator.md), which chose muRISCV-NN as the kernel library.

## What was run

`asic/librelane/chip/ai/mnn/`: the library (submodule `addins/muriscv-nn`, TUM, Apache-2.0, commit `8f15b68`) used as it is, its scalar C
kernels (no V or P extension), compiled with `-O2` for `rv32imac_zicsr` together with the baseline's start file and link script. A 64 x 64
layer through `muriscv_nn_fully_connected_s8` with what TFLite Micro passes: input zero point 128, output zero point -128, per-tensor Q31
multiplier (2/3) and shift -6, clamp to int8. The output is compared byte by byte with an independent implementation of the quantization
(64-bit integers, rounding to nearest with ties away from zero) written in `main.c`; then the cycles of the call (`mcycle`, 16 calls) and of the
library's `muriscv_nn_requantize` alone over the 64 accumulators.

## Results

| | cycles |
|---|---|
| library call, 64 x 64 layer | **84 379** |
| the same with the library's inline-assembly requantization (`-DMURISCV_NN_USE_REQUANTIZE_INLINE_ASSEMBLY`) | 102 228 (slower) |
| `muriscv_nn_requantize` of the 64 outputs alone | **5 263** (82 per output) |
| the same with the inline-assembly variant | 6 168 (96 per output) |
| step 0's best C kernel for the same layer (`ai/baseline`) | 126 513 |
| the unit, the layer alone (`ai/gemv`) | 1 504 |

The library's output equals the independent reference. The extra buffer the library asks for (`get_buffer_size`) is 0 bytes in the scalar
build. The image is 2.9 KB of code and 4.7 KB of data and stack for this layer.

## What it says

- The library's kernel is 1.5 times faster than step 0's best hand-written one (84 K against 126 K; about 19 cycles per MAC once the
  requantization is taken out, against 31). The unit's advantage over it is therefore 56 times for the layer alone, not 84.
- The requantization is **not cheap**: 82 cycles per output, 6 % of the library's call and **3.5 times the time the unit takes for the whole
  layer**. A unit that returns the raw accumulator (the choice of the ADR) leaves this in software: a layer would take about 6 800 cycles
  (1 504 + 5 263 + preparing the bias; not measured end to end), about 12 times faster than the library, not 56. Requantizing in the unit
  (option 2 of the ADR, a 32 x 32 multiplier with the library's rounding) would bring it back towards 1 500 but costs area and cycle time.
- The portable requantization is faster than the library's own inline-assembly one (its source says the portable one is probably more
  efficient; it is, here).
- Not shown: anything about a whole model, the V and P kernels (the core has neither extension), TFLite Micro itself.

## Reproduce

```bash
git submodule update --init addins/muriscv-nn
make -C asic/librelane/chip/ai/mnn          # build/mnn.bin; DEFS=-D... and BUILD=... for variants
asic/librelane/chip/uart_load.py <FT232R> asic/librelane/chip/ai/mnn/build/mnn.bin
```
