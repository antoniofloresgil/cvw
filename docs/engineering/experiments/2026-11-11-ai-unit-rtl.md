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

## RAW mode: the int32 accumulator (2026-11-12, simulation)

CTRL bit 2 (`RAW`): the unit writes `W x + bias` as one int32 per output (Y is OUT words, so OUT * 4 bytes must lie in the usable RAM), and
ignores MULT, SHIFT (a shift above 47 is accepted) and RELU. It is for the library kernels of muRISCV-NN and CMSIS-NN, whose requantization
(Q31 multiplier, rounding, zero points) the unit's is not ([ADR 0024](../decisions/0024-edge-ai-accelerator.md)); the library requantizes the words
in software. The unit writes each word as soon as the row ends (a byte-mode run writes one word per four rows), so it takes longer:

| Case | byte mode | RAW |
|---|---|---|
| 64 x 64 | 1504 | 1650 |
| 63 x 64 | 1482 | 1624 |
| 3 x 1024 | 1047 | 1054 |
| 7 x 12 | 71 | 92 |
| 1 x 4 | 14 | 13 |

`gemv` has six RAW shapes (the extreme one is a 1024-long dot product of -128 with -128), three refusals (Y reaching into the trace buffer, Y not aligned, W in the
boot ROM) and a byte-mode run after the RAW ones, all passing in `chipsim-ai`; lint is clean for `asic_soc_rv32imac_ai`. The test found a bug of the first
version: the check of a start used the old value of the RAW register, because the write that starts a run is the one that sets RAW; it now uses the bit
being written. **On the board on 2026-11-12** (Vivado bitstream of the AI chip with the trace register and RAW: 12,712 LUTs, 7,692 flip-flops, 27 more of each than without RAW,
worst slack +14.3 ns, a half-cycle path): `AI GEMV OK`, every RAW and byte-mode figure above identical to the simulation. The 64 x 64 layer in RAW plus the library's requantization (5 263 cycles, [record](2026-11-12-muriscv-nn-fully-connected.md)) is
about 6 900 cycles.
