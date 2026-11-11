# 0024. An edge-AI unit for the microcontroller (prototype on the FPGA first)

Status: **proposed** (2026-11-11); no RTL written yet. Applies to the chip `asic_soc_rv32imac`
([ADR 0022](0022-asic-microcontroller.md)) and its FPGA build ([docs/fpga-chip.md](../../fpga-chip.md)).

## Context

The question is whether the microcontroller can get an AI unit, as edge parts do (Arm Ethos-U,
the NPUs of other RISC-V MCUs). What bounds the answer is in this chip, not in the idea:

- **Memory.** 64 KiB of RAM in eight macros, the last 8 KiB also the trace buffer while the trace is on.
  No XIP: the program and any weights are copied into the RAM by the bootloader (Zephyr's image
  limit is 56 KiB). A model's weights and activations must fit there, with the firmware.
- **Core.** RV32IMAC, no vector or packed-SIMD extension and no CORE-V eXtension Interface (CV-X-IF). The
  rule of the project is to leave Wally's core alone (upstream merges stay easy), so new
  instructions are the expensive option.
- **Bus.** The peripherals are APB slaves behind the AHB bridge. All eight `PSEL` of `uncore.sv` are
  used; `mcu_apb.sv` decodes `PADDR[15:12]` with 0-3 used (timer, watchdog, I2C, RTC), so its block 4
  is free and needs no change to the address decode. A bus master (DMA) would need arbitration
  in the core's bus, which the core's two masters (instruction and data) do not have today.
- **Physical.** The die cannot grow (about 20 um of room at the `Ant.e` limit), any RTL change
  repeats the physical flow (about 8-9 h), and the clock is 40 ns. The core's free area has not been
  measured.
- **FPGA.** The chip already runs on the Nexys Video (7 % of its LUTs, 4 of 740 DSP blocks), which makes
  it the place to try an idea before it costs a silicon revision.

## What exists (searched 2026-11-11)

Nothing found is an int8 inference unit that drops into this chip, open, verified, with a flow for IHP SG13G2. The nearest
thing to a complete open stack is Google's Coral NPU (first row), which is a whole accelerator core of another scale. The pieces:

| Project | What it is | Use for us |
| --- | --- | --- |
| [Coral NPU](https://github.com/google-coral/coralnpu) (Google, Apache-2.0; [announcement](https://research.google/blog/coral-npu-a-full-stack-platform-for-edge-ai/)) | An open NPU core for ultra-low-power edge SoCs: a scalar RISC-V core and an RVV 1.0 vector unit (`rv32imf_zve32x_zbb`, 128-bit SIMD), 8 KB instruction and 32 KB data tightly-coupled memory, AXI4 manager and subordinate ports, so an external CPU configures it and loads its memories. Verilator, cocotb and UVM testbenches, a compiler stack on IREE/MLIR (JAX, PyTorch, TensorFlow). Google puts the base design in the 512 GOPS range at a few milliwatts. The matrix unit (a quantized outer-product MAC engine) was announced as "later this year": a later report says it was completed, which was not checked against the repository. A commercial part (Synaptics) uses it. The repository has `synthesis/` and `fpga/` directories; no area, FPGA resource or open-PDK result was found. | The **reference to beat or borrow from**: it is the full-stack version of this idea. Its two TCMs are 40 KB, close to our 64 KiB, but it has its own core and an AXI manager port, which our bus does not have (option F). Too much silicon for a die that cannot grow, to be checked on the FPGA. |
| [CFU Playground](https://github.com/google/CFU-Playground) (Google, Apache-2.0) | A method and tools: profile a TFLite Micro model on an FPGA soft CPU (VexRiscv, LiteX; Nexys Video among the tested boards), pick an operator, add a custom function unit, measure again. FPGA and simulation only, no ASIC flow; "not an officially supported Google project". | The **method** (profile first, accelerate what costs). Not the code: its unit plugs into VexRiscv's instruction interface. |
| [X-HEEP](https://arxiv.org/html/2508.16959) (EPFL) | An open MCU platform for TinyAI, with cores CV32E20/40X/40P and accelerators on an OBI master/slave interface or CV-X-IF; reported at 0.15 mm2 (host, TSMC 65 nm), memory banks 44 % of its area. | An **architecture reference**: memory dominates, so near-memory and per-bank design matter more than MAC count. |
| NM-Carus / NM-Caesar ([paper](https://arxiv.org/abs/2406.14263)) | Near-memory vector units inside SRAM banks for X-HEEP: up to 28x and 53.9x faster than an RV32IMC on their tasks (post-layout simulation). | Shows how large the gain from keeping data in the memory is. Not reusable: they live inside X-HEEP's memory banks. |
| [CV-X-IF](https://github.com/openhwgroup/core-v-xif) (OpenHW) | The standard coprocessor interface of CV32E40X/P. | Wally has no such interface: **option D** below would first need it. |
| [TinyGPU-ML](https://github.com/AnishMall/tinugpu_ml) (NEORV32) | A command-driven int8 inference unit on MMIO: 16 signed int8 PEs into int32, bias, activation and requantization epilogue, GEMM/GEMV and 1x1/3x3 Conv2D by streaming im2col; random differential tests and a formal flow; FPGA target Gowin; license not stated; 3 stars. | The closest **design** to option A, and a good model for the register interface and the test method. |
| Student projects: [PicoRV32 + 8x8 systolic array](https://github.com/VLS005/Custom-RISC-V-SoC-with-INT8-Matrix-Accelerator), [near-memory int8 MAC on PicoRV32](https://github.com/madihaanjumshahzad-creator/RISC-V_near_memory_MAC), [1/4/8-PE parameterised unit](https://github.com/DD-SITE/riscv-ai-accelerator), [PicoRV32 MAC co-processor](https://github.com/DymShanks/riscv-tinyml-accelerator) | Small int8 MAC arrays behind AXI-Lite or custom instructions, mostly FPGA or RTL simulation. | Ideas only; verification and licenses vary. |
| [A low-power RISC-V MCU with an integrated NN accelerator](https://zenodo.org/records/22657507) | RV32IMC, 128 KB SRAM, 32 KB scratchpad, DMA, 16 int8 MACs with requantization and ReLU. | The same shape as option A with DMA. No RTL release found. |
| [Tiny Tapeout INT8 dot-product accelerator](https://github.com/Joonsense/tt-pin-dot-accelerator) (SKY130) | One tile: pipelined Booth MAC, a 64-to-10 digits network, checked on the post-layout netlist. | Proof that a very small int8 unit has been closed on an open PDK. Not RISC-V. |

A large accelerator is the wrong size for 64 KiB of RAM. A search result attributes to one paper (not read in full, to be checked before it is quoted)
a loosely coupled Gemmini array at about 9.6x the power and 18x the area of a tightly coupled design for a 3 % gain on ResNet-50
([Frontiers 2022](https://www.frontiersin.org/journals/electronics/articles/10.3389/felec.2022.898273/full)).
Nothing found targets IHP SG13G2. The summaries of the projects above come from their README files and abstracts, not from running them.

## Options

| | What | Core change | Gain | Main risk |
| --- | --- | --- | --- | --- |
| **A** | A memory-mapped unit (APB slave): int8 MAC lanes into int32, a scratchpad the CPU fills, a bias, requantization and clamp epilogue | None | Bounded by the APB transfers (one 32-bit word, four int8, per access) | Data movement may eat the gain |
| **B** | As A, plus a bus master that reads the RAM itself | A new master on the core's bus | Higher | The arbitration is intrusive and the AHB structure is shared with the cores |
| **C** | Custom instructions (a packed int8 dot product, as the PULP/CORE-V extensions) in the integer unit | Decoder, ALU and hazards | High for the dot product | Touches the core, hard to keep merging upstream |
| **D** | CV-X-IF and a coprocessor | The interface in the core | High | The interface does not exist in Wally |
| **F** | Attach the Coral NPU as a separate accelerator core: AXI4 to AHB, the CPU loads its TCMs and starts it | A bridge, and an arbiter for its manager port | High, with a toolchain | Size (not measured) and a second core to boot; the AXI side needs a bridge that Wally lacks (it has `ahbwishbonebridge.sv` only) |
| **E** | Software only: the M extension, `Zbb`, careful kernels | None | The baseline | None; it is what the others are measured against |

## Decision (proposed; direction set by the user on 2026-11-11: B)

Build **B**: the unit of A with a **bus master of its own** that reads the activations and the weights from the RAM, for the
data movement that bounds A, measured against **E** on the FPGA. A's register interface stays as the control path (the CPU
writes addresses, sizes and a command; the unit fetches by itself). In parallel, and without touching
the chip, find out what the **Coral NPU** costs on the Nexys Video (build its FPGA target, read its LUT, BRAM and DSP use and its
clock) and run its examples: that gives the reference for what a full open NPU is, and F becomes a decision with numbers.

1. **A unit `ai` (its control registers as block 4 of `mcu_apb`)**, parameter-gated and off by default, so that the
   address decode and the core stay as they are. First version: `LANES` (4, 8, 16) signed int8
   multipliers into int32 accumulators, two operand windows (activations and weights) that the CPU
   fills a word at a time, a dot-product / GEMV tile command, and the epilogue (bias, a fixed-point
   multiplier and shift, clamp, ReLU). Poll the status; an interrupt only later (the MCU has four
   interrupt lines today, one per block).
2. **The reference is software on the same chip** (it stays the first step: it says what B has to beat): an int8 kernel of the CMSIS-NN kind, cycles per
   MAC measured on the RTL simulation and on the board. Nothing is claimed about speedups before it.
3. **The check** is a differential test against a Python/numpy model with random data, as TinyGPU-ML does,
   in cocotb; then a Zephyr driver and the same test on the Nexys Video.
4. **The model** is a small keyword-spotting network (the MLPerf Tiny DS-CNN is the usual one; from memory
   about 38 K parameters, which has to be checked against the benchmark's own description) because it is
   the one that can fit 64 KiB with the activations. The vision models do not fit.

Peak throughput of `LANES` MACs per clock is 147 MMAC/s for 8 lanes at the FPGA's 18.4375 MHz; it is a
ceiling, since the transfers through the APB set what is reached. That number is the one the prototype
measures.

## Open question: bring pieces here, or move to Google's repository (stated 2026-11-11)

Two ways to use the Coral NPU, to be decided with data, not now:

- **Here.** Keep this chip and Wally, and take what is useful from the Coral NPU repository (the unit's design, its
  compiler and simulator, its tests), as options A/F above.
- **There.** Take the Coral NPU repository as the base of the design and add an open ASIC flow for IHP SG13G2 to it
  (RTL generation from Chisel with Bazel, LibreLane, memory macros, a boot and debug story).

What is known so far, and from where:

| Fact | Source |
| --- | --- |
| The repository already has an open physical flow: OpenROAD (ORFS in a container) on **ASAP7**, a predictive 7 nm PDK, for `RvvCoreMiniAxi` at about 200 MHz (work in progress): about 1.43 million standard cells, a die of 441.5 um x 441.5 um, 38 % placement density, with fake RAMs. | `synthesis/BUILDING_CORALNPU_WITH_OPENROAD.md` of the repository |
| Our chip in IHP SG13G2 (130 nm): 90,429 cells, 1.21 mm2 of core, 40 ns, a die that cannot grow. | [experiment record](../experiments/2026-11-02-open-asic-flow.md) |
| The scalar `CoreMini` alone, on the Nexys Video's Artix-7 200T (Vivado 2024.2, out of context, 50 MHz target): 48,771 LUTs, 11,795 registers, 10 RAMB36, 6 DSPs, a 27.8 ns critical path with a latch-based clock gate. | measured 2026-11-11, `/datos/tmp/coral-synth` (the variants with the vector and matrix units follow) |

A first reading, to be confirmed: 1.43 million cells against our 90,429 is sixteen times more, and a 130 nm cell is much larger than
a 7 nm one, so the vector variant would not fit the die of this chip, and the scalar one is a large part of it. The Coral NPU in
IHP SG13G2 would be a different, bigger chip (a larger shuttle slot, a different package), not this microcontroller with an
accelerator. That would make "move there" a change of project, and "bring pieces here" the reading of the idea at the scale of
this chip (a small int8 unit, option A) with the Coral NPU as the reference.

Data to collect before the decision:

1. The resource use and clock of the three variants (`CoreMini`, `RvvCoreMini`, `VmeCoreMini`) on the Artix-7, and Wally's chip
   with the same Vivado script, so that the comparison uses one tool.
2. One Coral NPU example running in its simulator, and a small model through its compiler (IREE) to see what the toolchain gives.
3. What an open flow for IHP SG13G2 needs from Google's repository: the SRAM macros behind its `Sram` module, the
   clock-gate cells, the generated Verilog (Bazel and Chisel stay outside the flow), and a first area estimate with Yosys.
4. What the project gives up by moving: the Wally core (this repository's reason to exist), the chip's boot and debug work,
   the test board.

## ISA extensions for this (state on 2026-11-11, from web searches; the specifications themselves were not read)

None of the extensions that would implement this in instructions is ratified. Their status moves quickly: check the RISC-V Tech Hub
before relying on this table.

| Extension | What it does | State found |
| --- | --- | --- |
| RVV 1.0 (`Zve32x`) | Standard vectors, with widening integer multiply-accumulate (int8 to int16) | Ratified; what the Coral NPU's vector variant uses |
| `Zvdot4a8i` (formerly `Zvqdotq`) | Vector dot product: four int8 pairs accumulated into an int32 per element (`vqdot`, `vqdotu`, `vqdotsu`) | Draft; a January 2026 emulator patch set still calls it experimental; listed as RVS-1971 on the [Tech Hub](https://lf-riscv.atlassian.net/wiki/display/TECH/RISC-V+Vote+Status), ratification not confirmed |
| P (packed SIMD in the integer registers) | Operations on four bytes or two halves of a 32-bit register | [v0.6](https://github.com/riscv/riscv-p-spec/releases/tag/v0.6) development milestone approved 2026-09-28; in stabilization, changes still expected |
| IME, VME, AME (matrix) | Matrix multiply on the vector registers (IME, VME) or on a register bank of its own (AME) | Not ratified: plans for [VME](https://riscv.atlassian.net/wiki/spaces/VMEX/pages/663617995/Ratification+Plan) (TSC 2026-11-04, Board 2026-11-18), [IME](https://riscv.atlassian.net/wiki/spaces/IMEX/pages/598867969/IME+Ratification+Plan) (target 2026-08-27, apparently slipped) and [AME](https://riscv.atlassian.net/wiki/spaces/AMEX/pages/55083420/AME+Ratification+Plan) (2027). The Coral NPU's `Zvt` is the VME draft |
| Vendor: Xpulp / CORE-V `XCVsimd`, SiFive `Xsfvqdotq`, T-Head, Andes | SIMD int8 and dot products | Not standard; their current state was not checked |

What it means here: a lane of the unit computes four int8 products accumulated into an int32, which is what `Zvdot4a8i`
specifies, so the unit's semantics would carry over to the standard instruction if it is ratified. An instruction extension is
option C, and the only fitting one for a 32-bit core without vectors, P, is still moving and would touch the decoder, the ALU and the
hazards of Wally; the vector extensions do not fit (the Coral NPU's vector variant needs 282 % of the Artix-7 of the Nexys Video).
The unit with its bus master (B) is the accelerator: it removes the data movement that an instruction cannot.

## The bus master of B

The chip's bus is one AHB-Lite bus: `ebu.sv` arbitrates the core's instruction fetch and load/store onto it, and `uncore.sv`
decodes the address and drives the RAM and the APB bridge. A second master has two places to go:

| Where | Change | Verdict |
| --- | --- | --- |
| In `ebu.sv`, as a third requester | The core's bus unit, shared with the multicore variants | Intrusive: avoid |
| **In `uncore.sv`, a two-master arbiter before the address decode** | The uncore only, parameter-gated and off by default | **The place for it.** The core stays as it is |

The arbiter is small (a fixed priority, the core first or the unit first, to be chosen by the measurements; AHB-Lite masters
hold the bus for a burst). The unit's master is a read-only AHB-Lite master with INCR bursts and a word counter; it writes its
results back through the same master or leaves them in its own scratchpad for the CPU to read (a choice for the first RTL). The
chip has no data cache, so the unit reads what the core wrote without a coherence problem; the FPGA build of the chip is the same.
The ceiling is one 32-bit word (four int8) per clock after the address phase of a burst, against several clocks per word through
the APB bridge when the CPU feeds the unit: that gain is what the prototype has to measure, and it is an estimate until then.

## Licenses (read 2026-11-11 from each repository's `LICENSE` and GitHub's report; file headers and submodules not read)

This repository is `Apache-2.0 WITH SHL-2.1` (the Solderpad Hardware License 2.1 wraps the Apache License 2.0).

| Candidate | License | Code may be reused |
| --- | --- | --- |
| Coral NPU, CFU Playground, Tiny Tapeout int8 dot product, SNAX / OpenGeMM (`snax_cluster`) | Apache-2.0 | Yes |
| X-HEEP | Solderpad 0.51 (optionally Apache-2.0) | Yes; its submodules may differ |
| CV-X-IF | Solderpad 2.1 | Yes |
| NEORV32 | BSD-3-Clause | Yes, keeping the notice |
| near-memory MAC on PicoRV32 | MIT | Yes, keeping the notice |
| TinyGPU-ML, the 8x8 systolic PicoRV32 SoC, the 1/4/8-PE unit, the PicoRV32 MAC co-processor | none declared | **No**: ideas only, unless the authors add a license |

**What to reuse for B.** For the MAC datapath nothing is a drop-in: CFU Playground's `macc.py` units are Amaranth Python
written for its instruction interface, the Tiny Tapeout unit is built for one tile's pins, and the Coral NPU and OpenGeMM are
Chisel generators coupled to their own memory systems. A lane is a few lines of SystemVerilog (an int8 by int8 multiplier and an
adder tree); the work is in the control (tiling, the epilogue) and in the tests, and it is written here. For the bus master, the
candidates (X-HEEP's DMA subsystem, `pulp-platform/idma`) speak OBI or AXI, not AHB; Wally's own `ahbinterface.sv` and the
read side of `ebu.sv` are the clearest base, with this repository's license. Nothing is copied from a project without a license.

## What it does not decide

- **Silicon.** No ASIC change until the prototype shows a gain that compensates one more run of the
  physical flow, with the area measured (Yosys, then the floorplan) against the die that cannot grow.
- **Where the weights live.** With 64 KiB and no XIP, the useful model size is small. The flash reader that
  ADR 0022 leaves as a possible next revision is what lifts that limit, and it would be needed with or without
  the AI unit. For the FPGA the RAM can be larger (block RAM is plentiful), which separates "does the unit
  help" from "does the model fit".
- **Licenses.** Nothing from the projects above is copied; their license and quality must be read before
  any reuse (TinyGPU-ML states none).

## Design of the first RTL (step 1, written 2026-11-11 after the step 0 numbers)

What step 0 and the RTL say: the software costs 25 to 32 cycles per MAC at an IPC of 0.2 (see the
[baseline record](../experiments/2026-11-11-ai-software-baseline.md)), and the RAM of the chip (`RAM_LATENCY` 0, `ram_ahb.sv`) answers a
pipelined read every clock, with one lost clock only for a read right after a write. So the bus gives one 32-bit word, four int8, per
clock, and the unit is built around that: **`AI_LANES` = 4**, the number a 32-bit bus can feed (more lanes only pay with a batch that
reuses each weight word, which the first version does not have). Read from the RTL, not yet measured.

The first operation is a matrix-vector product, the core of a fully connected layer and of a pointwise convolution:

- **Operands:** the weights W (int8, row-major `OUT` x `IN`, `IN` a multiple of 4) stay in the RAM and the unit's master streams them
  one word per clock; the input vector X (up to `AI_X_BYTES`, 1 KiB at first) sits in a small scratchpad inside the unit, loaded once
  by the unit from RAM (a burst), so only W crosses the bus per MAC.
- **Per output row:** `IN/4` clocks of 4 multiplications (signed int8 x int8) into one int32 accumulator, then the epilogue: add the
  int32 bias (read from RAM), multiply by a 32-bit multiplier, shift right (rounding as the reference does), clamp (ReLU clamps to
  0..127, otherwise -128..127), pack four results per word and write them to `Y`. The first epilogue is the baseline's exact formula,
  `((acc + bias) * M) >> S` with a 64-bit product, so the test compares bit by bit with `chip/ai/baseline/main.c`.
- **Registers** (block 4 of `mcu_apb`, 32-bit): `CTRL` (start, relu), `STATUS` (busy, done, error: a bus error stops the unit), `IN`, `OUT`,
  `W_ADDR`, `X_ADDR`, `BIAS_ADDR`, `Y_ADDR`, `MULT`, `SHIFT`. Polling only; an interrupt is step 4.
- **Estimate** for the 64 x 64 layer: 64 rows x (16 weight words + about 4 clocks of epilogue and bus turn) = about 1300 clocks, against
  126 000 in software: about 100 times faster, at the price of the arbiter's clocks lost to the core. The number the step 2 test has to
  confirm or deny, on the board.
- **Gate:** `AI_SUPPORTED` (default 0) in `config.vh`, so no other configuration changes; `bin/actconfig-sync`'s parameter list is not
  involved (it is not an ISA extension).

## Possible improvement: a real kernel library for the step 3 model (looked at 2026-11-12, from web pages only; nothing built)

Step 0's baseline is four hand-written C kernels, not a library. For step 3 (a keyword-spotting model) the reference could be CMSIS-NN, the
Apache-2.0 int8/int16 kernel library of Arm that TensorFlow Lite for Microcontrollers (TFLM) calls on Arm cores, and the driver
(`wally_ai_run`) could replace its fully connected kernel.

What the repositories say:

- [CMSIS-NN](https://github.com/ARM-software/CMSIS-NN): CMake build that needs `TARGET_CPU`; every operator has a pure C implementation (made
  for Cortex-M0/M3); it says the C code can be built for a host "with minor stubbing" and does not mention RISC-V. int8 operators: Conv2D,
  DepthwiseConv2D, Fully Connected, Batch Matmul, Add, Mul, pooling, Softmax, LSTM, SVDF. It has not been compiled here.
- [muRISCV-NN](https://github.com/tum-ei-eda/muriscv-nn) (TUM, Apache-2.0): a fork of CMSIS-NN for RISC-V with portable scalar C kernels
  and kernels for the V and P extensions, a TFLM integration (`Integration/tflm`), run on the MLPerf Tiny models. Its page does not say RV32IMAC
  explicitly, which operators it covers, or when it was last updated. It is the first thing to try for a RISC-V reference.
- A keyword-spotting model: Arm's [ML-zoo](https://github.com/ARM-software/ML-zoo/tree/master/models/keyword_spotting/micronet_small) has
  `micronet_small` (int8 TFLite), but that repository was archived by its owner on 2025-07-18 and its page gives no sizes or accuracy. A
  DS-CNN of about 25 K parameters is said to need an arena of about 22 KB (a third-party page, not measured). The chip's RAM is 56 KiB
  usable (the last 8 KiB are the trace buffer), so the arena, the model's weights (in RAM or the BOOTROM-loaded image) and the stack have
  to fit together: to be measured, not assumed.

What it would take, in order: build muRISCV-NN (or CMSIS-NN's C kernels) for `rv32imac_zicsr`, run one quantized model on the chip in
simulation and record cycles per layer; then swap the fully connected kernel for the unit and compare accuracy bit by bit (the unit's
requantization `((W x + bias) * MULT) >> SHIFT` is the TFLite scheme, but the rounding of CMSIS-NN's requantization has to be checked
against the unit's plain arithmetic shift before any bit-exact claim); then see what share of the model's cycles are in layers the unit
can take (the unit does fully connected layers only; convolutions would have to be lowered to matrix-vector products or stay in software).

## Steps and what ends each

| Step | Exit |
| --- | --- |
| 0. Software baseline: an int8 dot product and a small fully-connected layer, cycles per MAC | A table in an experiment record |
| 0b. Coral NPU on the Nexys Video: build, resources, clock, one of its examples | A record with its resource use and what a coprocessor next to Wally would cost |
| 1. RTL of the unit, lint and cocotb differential test | Passes on random data; `lint-wally` clean. **Done 2026-11-11 in simulation**: [record](../experiments/2026-11-11-ai-unit-rtl.md), 64 x 64 layer in 1488 cycles against 126 513 in software |
| 2. Zephyr driver and the FPGA build | The same test on the board; cycles per MAC against step 0. **Zephyr driver and FPGA build done 2026-11-11, board test pending**: `chipsim-ai` passes (64 x 64 layer: unit 1496 cycles, whole driver call 2353, software under Zephyr 223 024); the free flow closes `asic_soc_rv32imac_ai` at 18.44 MHz (Fmax 19.88), 22 057 LUTs, 11 DSP48, 16 RAMB36 + 2 RAMB18 |
| 3. A keyword-spotting model on it | Accuracy equal to the reference, cycles and RAM used |
| 4. Decision on B, an interrupt, and the ASIC | Written in this ADR or a successor |
