Wally supports the following boards

1. ArtyA7
2. vcu108
3. vcu118 (Do not recommend.)
4. genesys2
5. nexysa7
6. nexysvideo

# Quick Start

## Build FPGA

```bash
cd generator
make <board name> FLOW=vivado
# or, for the reduced open-source Artix-7 flow:
make <board name> FLOW=opensource
```

Example:
```bash
make vcu108
make nexysvideo FLOW=vivado
make nexysvideo FLOW=opensource
```

For the Nexys Video, the `FLOW=opensource` build uses LiteX/LiteDRAM for the
DDR3 controller and PHY (no Vivado IP). See
[docs/fpga-opensource-litedram.md](../docs/fpga-opensource-litedram.md) for the
design and the tool requirements. LiteX is installed by
`bin/installation/litex-install.sh` (run as part of
`bin/wally-tool-chain-install.sh`).

## Make flash card image
`ls /dev/sd*` or `ls /dev/mmc*` to see which flash card devices you have.
Insert the flash card into the reader and `ls /dev/sd*` or `/dev/mmc*` again.  The new device is the one you want to use.  Make sure you select the root device (i.e. `/dev/sdb`) not the partition (i.e. `/dev/sdb1`).

```bash
cd $WALLY/linux/sd-card
```

This following script requires root.

```bash
./flash-sd.sh -b <path to buildroot> -d <path to compiled device tree file> <flash card device>
```

Example with vcu108, buildroot installed to `/opt/riscv/buildroot`, and the flash card is device `/dev/sdc`

```bash
./flash-sd.sh -b /opt/riscv/buildroot -d /opt/riscv/buildroot/output/images/wally-vcu108.dtb /dev/sdc
```

Wait until the the script completes then remove the card.

## FPGA setup

For the Arty A7 insert the PMOD daughter board into the right most slot and insert the sd card.

For the VCU108 and VCU118 boards insert the PMOD daughter board into the only PMOD slot on the right side of the boards.

Power on the boards. For Arty A7 just plug in the USB connector. For the VCU boards make sure the power supply is connected and the two usb cables are connected. Flip on the switch.
The VCU118's on board UART converter does not work. Use a spark fun FTDI usb to UART adapter and plug into the mail PMOD on the right side of the board.  Also the level sifters on the
VCU118 do not work correctly with the digilent sd PMOD board.  We have a custom board which works instead.

```bash
cd $WALLY/fpga/generator
vivado &
```

Open the design in the current directory `WallyFPGA.xpr`.

Then click "Open Target" under "PROGRAM AND DEBUG".  Then Program the device.

## Connect to UART

In another terminal `ls /dev/ttyUSB*`. One of these devices will be the UART connected to Wally. You may have to experiment by the running the following command multiple times.

```bash
screen /dev/ttyUSB1 115200
```

Swap out the `USB1` for `USB0` or `USB1` as needed.

## Linux on Nexys Video

The `nexysvideo` target uses a 20 MHz CPU clock and 512 MiB of DDR3 memory.
Connect the board's PROG USB port for JTAG and its UART USB port for the serial
console. The UART is configured for 115200 baud, 8 data bits, no parity, one stop
bit, and no flow control. Use `/dev/serial/by-id/` to identify the UART device.
See the [Digilent reference manual](https://digilent.com/reference/_media/reference/programmable-logic/nexys-video/nexys-video_rm.pdf)
for the board's connector locations.

From the repository root, build the bitstream and the board's device tree:

```bash
source /path/to/Vivado/settings64.sh
source ./setup.sh
make -C fpga/generator nexysvideo
dtc -I dts -O dtb linux/devicetree/wally-nexysvideo.dts \
    -o "$RISCV/buildroot/output/images/wally-nexysvideo.dtb"
```

The bitstream is `fpga/generator/WallyFPGA.runs/impl_1/fpgaTop.bit`.
Program it with Vivado Hardware Manager. Rebuild after RTL changes; an existing
bitstream does not automatically incorporate them.

The supplied Buildroot configuration embeds the root filesystem in the kernel.
The Nexys Video device tree therefore uses the kernel's built-in initramfs and
does not declare an external initrd or a virtual disk root device.

To prepare a microSD card, connect it to a reader on the host and identify its
whole-disk device with `lsblk`. The following command erases the selected card;
replace `/dev/sdX` with the verified card device:

```bash
cd "$WALLY/linux/sdcard"
./flash-sd.sh -b "$RISCV/buildroot" \
    -d "$RISCV/buildroot/output/images/wally-nexysvideo.dtb" /dev/sdX
```

Insert the prepared card into the Nexys Video, open the UART console, and program
the FPGA. The bootloader reads the device tree, OpenSBI, and kernel from the first
three GPT partitions. A successful Linux boot eventually displays the
`WallyHostname login:` prompt. Without a prepared card, only the bootloader can
be tested.
