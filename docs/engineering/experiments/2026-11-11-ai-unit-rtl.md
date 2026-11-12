# AI unit, first RTL: results in simulation

Status: **passes in the RTL simulation of the chip on 2026-11-11** (`asic_soc_rv32imac_ai`, test `ai_gemv`) and **on the Nexys Video on
2026-11-12** (see "On the board" below). Not synthesized for the ASIC: no ASIC area or clock figures exist. Step 1 of [ADR 0024](../decisions/0024-edge-ai-accelerator.md); the design is
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
| layer 64 x 64, bias, ReLU | 1504 | 1557 | 126 513 (word x2) |
| 63 x 64 | 1482 | 1541 | |
| 3 x 1024 | 1047 | 1106 | |
| 1 x 4 | 14 | 54 | |

(The first run of this record gave 1488, 1467, 1047 and 13 unit cycles; the table is from the current `chipsim-ai` run, which equals the board's
digit for digit. I did not trace the difference to a change, there is only one commit of the unit's RTL.)

The 64 x 64 layer is **84 times faster** than the best C kernel: 0.37 cycles per MAC against 30.9. The estimate in the ADR was about
1300 cycles; the extra comes from the per-row start (one clock for the read-after-write stall of the result store every four rows, the
two epilogue clocks and the response latency). About 15 % of the 1504 clocks are not MACs, so a deeper pipeline between rows
(issue the next row's reads during the epilogue) is the next gain if it is needed.

## On the board (2026-11-12)

`gemv.bin` loaded with `uart_load.py` on the Nexys Video, with the bitstream of the open flow and again with the one of Vivado 2024.2
(`asic_soc_rv32imac_ai`, both from before the trace register, 18.4375 MHz): `AI GEMV OK`, the nine shapes equal to the C reference bit by bit,
the nine arguments refused, and the unit working after them. The cycle counts are **identical to the simulation and between the two flows**
(1504 / 1557 for the 64 x 64 layer, 71 / 127, 45 / 89, 14 / 54, 1482 / 1541, 1047 / 1106), as expected: they are fixed by the RTL, not by the
tool. The Zephyr image of step 2 gave the same result (see ADR 0024). What this does not show: the unit with the trace register, the ASIC.

## What it cost, and what remains open

- The arbiter adds muxes in front of the uncore's address decoder; with `AI_SUPPORTED` 0 they are plain assignments (the chip's other
  configurations lint clean). The unit stalls the core while it owns the bus (a row at a time: the core waits at most about 20 clocks).
- Limits of the first version: RAM only (no external memory), RV32 with 32-bit AHB, vector up to 1 KiB, 16-bit signed multiplier,
  polling (no interrupt), weights and bias must not overlap the results, one command at a time.
- The 1 KiB vector memory is a flop/BRAM array: right for the FPGA, an SRAM macro or a smaller size for the ASIC.
- Not measured: resources and clock on the Nexys Video, power, the multiplier's timing at 40 ns in the ASIC flow.
