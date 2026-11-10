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
touch the ZSBL's `fpga/src/boot.mem`. Last result (nextpnr-xilinx): 20,215 LUTs (7 %), 7,021 flip-flops, 16 RAMB36 and one RAMB18, 4 DSP48; the
final timing report says 19.01 MHz for a clock of 18.44 MHz, a margin of 3 %, from the router's own model (the Linux build
of the open flow is used in the same way).

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

To run one of these, reset the chip only after `uart_load.py` is waiting, and close the previous run first: a loader that is still
running keeps the port and takes the bootloader's `W`.

## Not checked yet

* `zephyr/mcu` (I2C and the watchdog, which resets the chip), `zephyr/trace`, `zephyr/periph` (it needs a host that plays the pads), FreeRTOS, and the timing margin over many runs (the router reports 19.01 MHz for an 18.44 MHz clock).
* No JTAG (Debug Module, instruction trace): the pads to a Pmod are the next step.
