# The chip on an FPGA (Nexys Video)

`asic_soc_rv32imac`, the SoC of the ASIC (`asic/librelane/chip`), runs on the Digilent Nexys Video with the open-source flow, to
try the firmware (Zephyr, FreeRTOS) on real hardware before and besides the silicon. It is the same RTL and the same
configuration (`config/deriv/asic_soc_rv32imac`); only what is around it changes.

| | the chip | the FPGA (`fpga/src/fpgaChip.sv`) |
|---|---|---|
| Clock | 18.432 MHz oscillator | PLL from the board's 100 MHz: 100 x 59 / 5 / 64 = 18.4375 MHz (0.03 % above) |
| RAM, BOOTROM | 8 SRAM macros, preloaded ROM | block RAM (16 RAMB36 for the 64 KiB, one RAMB18 for the BOOTROM) |
| UART | pads | the USB-UART of the board |
| GPIO[7:0] | pads | SW[7:0] as inputs, LD[7:0] as outputs; an output pin reads back what it drives |
| SPI flash, JTAG, SD | pads | not connected (inputs tied to 0) |

Because the clock matches the test board's, the images of the chip run unchanged: the bootloader's default UART divisor (10) gives
115200 baud and Zephyr's devicetree clock (18.432 MHz) is right to 0.03 %.

## Build

```bash
source setup.sh
cd fpga/generator
make nexysvideochip                 # about 5 minutes: opensource-nexysvideochip/nexysvideochip.bit
```

`make nexysvideochip` builds the chip's bootloader (`asic/librelane/chip/boot.mem`) and preloads it in the BOOTROM, so it does not
touch the ZSBL's `fpga/src/boot.mem`. First result (nextpnr-xilinx): 20,215 LUTs (7 %), 7,021 flip-flops, 16 RAMB36 and one RAMB18, 4 DSP48; the
final timing report says 19.01 MHz for a clock of 18.44 MHz, a margin of 3 %, from the router's own model (the Linux build
of the open flow is used in the same way). That was before the instruction trace's line got a register (`etraceingress.sv`): the longest path,
from the load/store address (and the PMP checks) through `StallW` and the trace encoder to the sink's queue, was then cut in two, and
the same chip, on the same seed, went from 20.86 (a later run of the sources of the 19.01 above) to 28.90 MHz (one run each, 2026-11-12).

`make nexysvideochip-vivado` builds the same sources, clock and pins with Vivado 2024.2 (`chip-vivado.tcl`, non-project flow, default strategies)
into `vivado-nexysvideochip/` (`VIVADO_OUT=<dir>` changes it), in about 2 minutes. Before and after the trace register: 11,325 and 11,316 LUTs,
7,020 and 7,094 flip-flops; the slowest full-cycle path went from 35.3 ns (load/store address to the trace sink's queue, 28 levels) to
33.1 ns (load/store address to the RAM's address, 25 levels), against a period of 54.2 ns. Paths that end in falling-edge registers
(the register file, the SPI) get half a period, and the reset (3,000 destinations) is their worst path. The Vivado bitstreams of the plain chip have not been run on the board (the AI chip's has: see below).

`make nexysvideochip CHIPCONFIG=asic_soc_rv32imac_ai` builds the chip with the AI unit (`src/uncore/ai`, registers at 0x10084000) into the same
directory, so it overwrites the plain bitstream (build the plain one again to go back). Result of 2026-11-11: 22,057 LUTs (+1,842 over the
plain chip), 7,556 flip-flops (+535), 11 DSP48 (+7), 16 RAMB36 and 2 RAMB18 (+1); timing 19.88 MHz for 18.44 MHz (before the trace register). Run on the board on 2026-11-12: see below.

`make nexysvideochip-vivado CHIPCONFIG=asic_soc_rv32imac_ai` builds the same sources, clock and pins with Vivado 2024.2 (`chip-vivado.tcl`, non-project
flow, default strategies, no timing push) into `vivado-nexysvideochip/`, to compare with the open flow (2026-11-11, before the trace register above; about 2 minutes against about 5 for the open flow):

| | Open flow (Yosys + nextpnr) | Vivado 2024.2 |
|---|---|---|
| LUTs | 22,057 | 12,684 |
| Flip-flops | 7,556 | 7,591 |
| DSP48 | 11 | 8 |
| RAMB36 / RAMB18 | 16 / 2 | 16 / 2 |
| Timing at 18.44 MHz | Fmax 19.88 MHz (router's model) | slowest full-cycle path 35.3 ns of 54.2 (load/store address to the trace sink's queue, about 28 MHz); the half-cycle reset paths are the worst slack (+14.4 ns) but would hold to about 40 MHz |

The AI unit alone in Vivado (`report_utilization -hierarchical` on the routed design): 1,161 LUTs, 561 flip-flops, 1 RAMB18 (the x memory) and 4 DSP48. The
slowest path that ends in it (`XMem` to `Acc`, 21 logic levels) takes 19.0 ns against the 54.2 ns period, a slack of 35.1 ns. The open flow's difference
with and without the unit was +1,842 LUTs, +535 flip-flops and +7 DSP48. The AI chip's bitstreams, from the open flow and from Vivado (both from before the trace register), **ran on the board on 2026-11-12**: the
`gemv` test, the software baseline and the Zephyr `ai` image (`make APP=ai OVERLAY=ai.overlay`, the overlay that enables `ai0`; the simulation's
`ai-sim.overlay` also changes the UART speed, so it does not do on the board) pass with the same cycles as the simulation and the same in both flows
(64 x 64 layer: unit 1496 to 1504 cycles, Zephyr call 2353, C 126 513 bare metal and 219 121 under Zephyr). The records are in
[the unit's](engineering/experiments/2026-11-11-ai-unit-rtl.md) and [the baseline's](engineering/experiments/2026-11-11-ai-software-baseline.md).
The same chip **with the trace register** (`ai-baseline` after merging `main`, rebuilt 2026-11-12), checked on the board in both flows: `gemv`, the baseline
and the Zephyr `ai` image pass again, with the same cycles. Open flow: 21,933 LUTs, 7,630 flip-flops (+74, the register), 11 DSP48, 16 RAMB36 and 2 RAMB18;
Fmax **26.53 MHz** at the last pass of nextpnr (one run; 19.88 before the register). Vivado: 12,685 LUTs and 7,665 flip-flops; the slowest full-cycle path is
33.5 ns of 54.2 (38 logic levels, from the PMP configuration registers to the write pointer of the trace sink), against 35.3 ns before the register, so
the register helps the AI chip less than the plain chip (the path now ends in the sink's write enable, not in its queue); the half-cycle paths are
unchanged (worst slack +13.9 ns). In the Zephyr image the whole call of the driver (`call` in its output) took 2,353 cycles in some runs and 5,900 to
6,250 in others with the same image and the same bitstream (also with the bitstreams from before the register), and the unit's own cycles ranged from
1,479 to 1,496; the cause is not known, so the 2,353 of the ADR is the best case.

## Run

```bash
openFPGALoader -b nexysVideo opensource-nexysvideochip/nexysvideochip.bit      # volatile
cd asic/librelane/chip/zephyr && make                                           # build/zephyr/zephyr.bin
asic/librelane/chip/uart_load.py /dev/serial/by-id/usb-FTDI_FT232R_USB_UART_<serial>-if00-port0 \
    asic/librelane/chip/zephyr/build/zephyr/zephyr.bin
```

The console is the board's **FT232R** (the `FTDI_FT232R` entry of `/dev/serial/by-id`), not the Digilent device that
openFPGALoader programs through: that one disappears for about ten seconds at every programming. The FT232R does not, so
start `uart_load.py` first and program the FPGA afterwards (or press CPU RESET): the bootloader sends its `W` once, as soon as
the FPGA is configured.

The bootloader reads its straps from the switches at reset: SW5 up skips the flash (the FPGA has none, so the bootloader
falls back to the UART anyway), and SW[4:0] is the UART divisor, 10 when all are down. With another divisor the bootloader
runs at 18.4375 MHz / (16 x divisor); pass that rate to the loader with `--boot-baud` (SW3 alone up is divisor 8,
`--boot-baud 144043`). Zephyr and FreeRTOS set their own rate, 115200, after they start, which is the loader's
`--baud` for the console.

Any other image of the chip loads the same way (`zephyr/uart_irq`, `zephyr/timer`, FreeRTOS, ...). The Zephyr demos that
need a counterpart at the pads (the I2C device, the SPI flash, the PWM capture) have none on the board: the GPIO demo works with SW4
(input) and LD5 (output), and the PWM on GPIO[3:0] shows on LD[3:0].

## Checked on the board

2026-11-09, Nexys Video, the bitstream of this build: the bootloader loaded the `app` image of Zephyr (37,192 bytes, checksum
returned and right) and the demo ran to `ZEPHYR OK`: threads A and B in their own memory domains keep their data, and each
forbidden access ends with the cause that the RTL simulation gives (store 7, load 5, jump into data 1, the refused system
call 8). One check failed the first time, for a reason that only a board shows: the refused system call's oops runs with
interrupts on, the console is slow, and the timer's tick arrived before the handler read `mcause`; the demo now treats an
interrupt cause there as the `ecall`.

2026-11-10, same bitstream, all of SW[4:0] down (bootloader at 115200 baud, no `--boot-baud` needed): the `app` image ran to
`ZEPHYR OK` again. The `gpio_demo` image (`asic/librelane/chip/zephyr/gpio_demo`, built with `make APP=gpio_demo BUILD=build-fpga-gpio`)
lights LD0 to LD7 in turn, which was seen in order, and then prints the eight switches every half second: raising SW0, SW1, ... SW7
one at a time, with the others down, gave `00000001`, `00000010`, ... `10000000`, so every switch and every LED is on the pin of its
GPIO. That includes SW4-7 and LD5-7, whose pins came from memory of Digilent's master constraints. (A first run lost lines of the
console because an older `uart_load.py` still had the port open: close the previous loader before starting another.)

Later the same day, two more images ran on the board, loaded by `uart_load.py`:

* `zephyr/uart_irq`, with `--send abc --send-after "uart ready"`: the three letters come back as `ABC`, then `UART IRQ OK`: the
  console UART's receive interrupt through the PLIC.
* `zephyr/timer`, built with `make APP=timer BUILD=build-fpga-timer FPGA_TIMING=1`, to `TIMER OK`: the counter, its top value and
  callback, five kinds of alarm, the capture, the PWM and the RTC. `FPGA_TIMING` gives the demo the timings of a person at the board
  instead of the simulation's (`timer/main.c`): the capture waits 40 s for edges, which come from raising and lowering SW2 (GPIO2) by hand,
  the RTC counts real seconds (the simulation's overlay makes it count a thousand per second), and the PWM period is 0.5 s. The
  capture measured the switch's own bounce (an interval of 2,584 clocks, 0.14 ms, among others of seconds); the exact intervals of
  chipsim's test (6000 and 4000 clocks) cannot be made by hand and were not checked. LD0 (25 %) and LD1 (75 %, inverted) blink in
  opposite phase, as the duty cycles say. LD3 gives a brief flash every period and LD2 was off on one run and on in another: those two channels are not
  configured by the demo, and what they show is what the alarm and capture tests left in their registers (`PWMOut = (Cnt < Ccr) ^ invert`
  in `src/uncore/mcu/timer_apb.sv`); chipsim does not look at them.

* `zephyr/mcu` (the I2C master and the watchdog), with no I2C device on the board: SCL and SDA are GPIO6 and GPIO7, so SW6 and SW7 are
  the lines (up reads high, as a pull-up; down reads low, a line held low). With both up the bus is free and nobody answers: the demo stops at
  `MCU FAIL i2c write -5` (`EIO`, a NACK at 0x50), as it should. With SW6 up and SW7 down, SDA is held low and every address is
  acknowledged: `i2c write ok`, `i2c read 00`, `i2c nack 0` (the address 0x51 is acknowledged too), `wdt fed`, and then a `W` on the
  UART: the watchdog, armed at 200 ms and fed three times, reset the SoC and the bootloader started again. So the master's transactions
  and the watchdog's reset work on the board; the data (0x5A out, a byte back) and the ACK/NACK difference between addresses need a real I2C
  device on GPIO6/GPIO7, which is the test board's job, and were not checked.

* `zephyr/trace`, built with `make APP=trace BUILD=build-fpga-trace FPGA_DUMP=1`: the instruction trace (E-Trace) of the chip on the board. The FPGA
  has no JTAG, which is how `chipsim` reads the sink's buffer, so with `FPGA_DUMP` the hart reads the buffer itself through `trRamData`
  after `trace ready` and prints it, a word per line. `asic/librelane/chip/trace_decode.py trace.log zephyr.elf` decodes it against the ELF
  with `testbench/debug/etrace/etracedecode.py` and checks what `chipsim`'s `zephyr_trace` checks. On the board: 988 bytes of packets, 5,952
  instructions, the workload, the worker thread, the semaphore calls, 8 context switches (at least 6 are needed) and the timer's interrupt
  handler after the three round trips. So the encoder, the RAM sink and the Trace Control Interface work in the FPGA build.
  Without `FPGA_DUMP` the image is byte for byte the one of `chipsim`.

* `zephyr/periph`, built with `make APP=periph BUILD=build-fpga-periph FPGA_TIMING=1`, to `PERIPH OK`. The demo is written for chipsim's testbench,
  which plays the pads, and `FPGA_TIMING` only widens the two interrupt waits (100 ms to 30 s) so that a person can make the edges with SW4
  (GPIO4). The UART's polled receiver echoed `abc` as `ABC` (`uart_load.py --send`); GPIO5 followed GPIO4 (SW4 up before the reset: LD5 on);
  the SPI transfer completed and returned zeros, because the board has no flash (chipsim's flash answers `WALY`: that content was not
  checked); the edge interrupts through the PLIC gave `gpio edges 010` (SW4 down, up, down), and the level interrupt fired once
  (`gpio level 1 once`) when SW4 went up. The PWM's registers were programmed (`pwm set`; the output enables are GPIO0, 1, 2 and 5);
  with a period of 10 us only the mean brightness shows, and LD1 (25 % high, as the demo's note explains) and LD2 (75 %) looked alike, so the duty
  cycles were not checked on the board (the `timer` image's slow PWM was: see above). With SW4 up at the reset the bootloader's divisor is
  16, 72,021 baud: start the loader with `--boot-baud 72021` (the first line of the program's console is then garbled when the loader changes speed).

* FreeRTOS (`asic/librelane/chip/freertos`, `make`; its image is 12,100 bytes), to `FREERTOS OK` with the switches all down: the producer's five
  messages through the queue (`rx 1` to `rx 5`) under the UART mutex, the software timer, the busy task that proves the tick preempts, and
  the demo's own checks of the tick count, the timer and the stack, although the board's clock is 18.4375 MHz and the configuration
  assumes 18.432 MHz (0.03 %). The static PMP protection gives the causes of the simulation: a store to data allowed (0), a store to the code
  7, an instruction fetch from the heap 1 and from a stack 1.

A leftover switch makes a later load fail without any message: after `periph`, SW4 stayed up and the bootloader (divisor 16, 72,021 baud)
no longer matched the loader's 115200, which waits for a `W` that never arrives. Put SW0-SW7 down before a reset, or use `--boot-baud`.

To run one of these, reset the chip only after `uart_load.py` is waiting, and close the previous run first: a loader that is still
running keeps the port and takes the bootloader's `W`.

## Not checked yet

* `zephyr/mcu` with an I2C device on the pads (see above), the contents of an SPI flash read by `zephyr/periph`, and the timing margin over many runs (the router reported 19.01 and 20.86 MHz before the trace register and 28.90 MHz after it, one run each, for an 18.44 MHz clock).
* No JTAG (Debug Module, instruction trace): the pads to a Pmod are the next step.
