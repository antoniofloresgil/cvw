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
asic/librelane/chip/uart_load.py /dev/ttyUSBn asic/librelane/chip/zephyr/build/zephyr/zephyr.bin
```

Put **SW5 up and SW0-4 down** before pressing CPU RESET: the bootloader reads its straps from GPIO[5:0] at reset (SW5 up skips the
flash, which the FPGA does not have; SW0-4 down keeps the divisor 10). `uart_load.py` waits for the bootloader's `W`, sends the
image, checks the checksum the bootloader returns and then shows the program's console; press CPU RESET once it is
waiting. Any other image of the chip loads the same way (`zephyr/uart_irq`, `zephyr/timer`, FreeRTOS, ...).

The Zephyr demos that need a counterpart at the pads (the I2C device, the SPI flash, the PWM capture) have none on the board: the
GPIO demo works with SW4 (input) and LD5 (output), and the PWM on GPIO[3:0] shows on LD[3:0].

## Not checked yet

* The pins of SW4-7 and LD5-7 in `fpga/constraints/opensource-NexysVideoChip.xdc` come from memory of Digilent's master constraints, not from
  the board's reference manual; the others are those of the existing Nexys Video constraints.
* The bitstream has not been loaded on a board yet.
* No JTAG (Debug Module, instruction trace): the pads to a Pmod are the next step.
