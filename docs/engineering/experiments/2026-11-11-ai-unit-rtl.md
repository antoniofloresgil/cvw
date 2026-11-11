# AI unit, first RTL: results in simulation

Status: **passes in the RTL simulation of the chip on 2026-11-11** (`asic_soc_rv32imac_ai`, test `ai_gemv`). Not yet on the Nexys Video,
not synthesized: no area, clock or board figures exist. Step 1 of [ADR 0024](../decisions/0024-edge-ai-accelerator.md); the design is
in that ADR, the code in `src/uncore/ai/ai_unit.sv` and the arbiter in `src/uncore/uncore.sv`.

## What was checked

`chip/ai/gemv` (firmware, C) runs on the chip's core and drives the unit through its registers, comparing every output byte with a
C reference and the bytes after OUT with a canary (the byte strobes of a partial last word). Nine shapes (64x64 with bias and ReLU twice,
7x12 and 5x4 with negative multiplier and no ReLU, 1x4, 63x64, 3x1024, shift 0 with a saturating multiplier, shift 47) and nine
arguments that must be refused (IN not a multiple of 4, zero, too long; OUT zero; shift 48; weights in the boot ROM, past the usable
RAM; results in the trace buffer, unaligned): all pass.

## Cycles

| Case | unit cycles | core cycles (start to done, with polling) | software (step 0) |
|---|---|---|---|
| layer 64 x 64, bias, ReLU | 1488 | 1531 | 126 513 (word x2) |
| 63 x 64 | 1467 | 1497 | |
| 3 x 1024 | 1047 | 1077 | |
| 1 x 4 | 13 | 56 | |

The 64 x 64 layer is **85 times faster** than the best C kernel: 0.36 cycles per MAC against 30.9. The estimate in the ADR was about
1300 cycles; the extra comes from the per-row start (one clock for the read-after-write stall of the result store every four rows, the
two epilogue clocks and the response latency). About 15 % of the 1488 clocks are not MACs, so a deeper pipeline between rows
(issue the next row's reads during the epilogue) is the next gain if it is needed. These are simulation cycles of the same RTL as the
FPGA, so they should carry to the board; the clock that the unit closes on the board and on the ASIC is not known yet.

## What it cost, and what remains open

- The arbiter adds muxes in front of the uncore's address decoder; with `AI_SUPPORTED` 0 they are plain assignments (the chip's other
  configurations lint clean). The unit stalls the core while it owns the bus (a row at a time: the core waits at most about 20 clocks).
- Limits of the first version: RAM only (no external memory), RV32 with 32-bit AHB, vector up to 1 KiB, 16-bit signed multiplier,
  polling (no interrupt), weights and bias must not overlap the results, one command at a time.
- The 1 KiB vector memory is a flop/BRAM array: right for the FPGA, an SRAM macro or a smaller size for the ASIC.
- Not measured: resources and clock on the Nexys Video, power, the multiplier's timing at 40 ns in the ASIC flow.
