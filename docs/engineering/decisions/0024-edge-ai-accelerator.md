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

## Decision (proposed)

Start with **A** on the FPGA, measured against **E**, and decide B only from the measurements. In parallel, and without touching
the chip, find out what the **Coral NPU** costs on the Nexys Video (build its FPGA target, read its LUT, BRAM and DSP use and its
clock) and run its examples: that gives the reference for what a full open NPU is, and F becomes a decision with numbers.

1. **A unit `ai` as block 4 of `mcu_apb`**, parameter-gated and off by default, so that the
   address decode and the core stay as they are. First version: `LANES` (4, 8, 16) signed int8
   multipliers into int32 accumulators, two operand windows (activations and weights) that the CPU
   fills a word at a time, a dot-product / GEMV tile command, and the epilogue (bias, a fixed-point
   multiplier and shift, clamp, ReLU). Poll the status; an interrupt only later (the MCU has four
   interrupt lines today, one per block).
2. **The reference is software on the same chip**: an int8 kernel of the CMSIS-NN kind, cycles per
   MAC measured on the RTL simulation and on the board. Nothing is claimed about speedups before it.
3. **The check** is a differential test against a Python/numpy model with random data, as TinyGPU-ML does,
   in cocotb; then a Zephyr driver and the same test on the Nexys Video.
4. **The model** is a small keyword-spotting network (the MLPerf Tiny DS-CNN is the usual one; from memory
   about 38 K parameters, which has to be checked against the benchmark's own description) because it is
   the one that can fit 64 KiB with the activations. The vision models do not fit.

Peak throughput of `LANES` MACs per clock is 147 MMAC/s for 8 lanes at the FPGA's 18.4375 MHz; it is a
ceiling, since the transfers through the APB set what is reached. That number is the one the prototype
measures.

## What it does not decide

- **Silicon.** No ASIC change until the prototype shows a gain that compensates one more run of the
  physical flow, with the area measured (Yosys, then the floorplan) against the die that cannot grow.
- **Where the weights live.** With 64 KiB and no XIP, the useful model size is small. The flash reader that
  ADR 0022 leaves as a possible next revision is what lifts that limit, and it would be needed with or without
  the AI unit. For the FPGA the RAM can be larger (block RAM is plentiful), which separates "does the unit
  help" from "does the model fit".
- **Licenses.** Nothing from the projects above is copied; their license and quality must be read before
  any reuse (TinyGPU-ML states none).

## Steps and what ends each

| Step | Exit |
| --- | --- |
| 0. Software baseline: an int8 dot product and a small fully-connected layer, cycles per MAC | A table in an experiment record |
| 0b. Coral NPU on the Nexys Video: build, resources, clock, one of its examples | A record with its resource use and what a coprocessor next to Wally would cost |
| 1. RTL of the unit, lint and cocotb differential test | Passes on random data; `lint-wally` clean |
| 2. Zephyr driver and the FPGA build | The same test on the board; cycles per MAC against step 0 |
| 3. A keyword-spotting model on it | Accuracy equal to the reference, cycles and RAM used |
| 4. Decision on B, an interrupt, and the ASIC | Written in this ADR or a successor |
