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

## Not checked yet

* The pins of SW4-7 and LD5-7 in `fpga/constraints/opensource-NexysVideoChip.xdc` come from memory of Digilent's master constraints, not from
  the board's reference manual; the others are those of the existing Nexys Video constraints. Their effect has not been seen (the
  switches were left in some position, and the LEDs not watched).
* The other Zephyr images, FreeRTOS, and the timing margin over many runs (the router reports 19.01 MHz for an 18.44 MHz clock).
* No JTAG (Debug Module, instruction trace): the pads to a Pmod are the next step.
