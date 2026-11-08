// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Bootloader of asic_soc_rv32imac, in its 512-byte BOOTROM at 0x1000: copies a program from an SPI
// flash, or loads it over the UART, into the RAM at 0x80000000 and runs it with sp at the top of
// the RAM.
//
// Straps, read from GPIO[5:0] at reset (GPIO 6 and 7 are I2C, whose pull-ups would read 1):
//   GPIO[4:0]  UART baud divisor: f_clk / (16 * divisor), or 10 if they read 0 (115200 baud with the
//              test board's 18.432 MHz oscillator, exactly)
//   GPIO[5]    1: skip the flash and load over the UART
//
// SPI flash, on chip select 0, read with the standard Read command (0x03, 3 address bytes) from
// address 0, at f_clk / 8 (the SPI's reset divisor):
//   'W' 'A' 'L' 'Y'   magic
//   size, 4 bytes, little endian (at most 64 KiB)
//   size bytes of the program
// With the magic and size right, the chip sends 'F' on the UART and runs the program; otherwise (no
// flash, or an erased one) it falls back to the UART.
//
// UART (8 data bits, no parity, 1 stop bit):
//   chip -> host  'W'                      ready
//   host -> chip  size, 4 bytes, little endian (at most 64 KiB)
//   host -> chip  size bytes of the program
//   chip -> host  8-bit sum of those bytes; then the chip runs the program.  A size over 64 KiB
//                 sends back '!' and waits for a new size.

  .equ UART,     0x10000000      // PC16550D, one register per byte
  .equ UART_RBR, 0               // receive buffer (DLL with LCR.DLAB)
  .equ UART_THR, 0               // transmit holding
  .equ UART_DLM, 1               // divisor latch MSB, with LCR.DLAB
  .equ UART_LCR, 3
  .equ UART_LSR, 5               // bit 0: data ready, bit 5: transmit holding empty
  .equ GPIO,     0x10060000
  .equ GPIO_INPUT_VAL, 0x00
  .equ GPIO_INPUT_EN,  0x04
  .equ SPI,      0x10040000      // SiFive-like SPI (src/uncore/spi_apb.sv)
  .equ SPI_CSMODE, 0x18          // 0: auto, 2: hold the chip select between frames
  .equ SPI_TXDATA, 0x48
  .equ SPI_RXDATA, 0x4C          // bit 31: receive FIFO empty
  .equ RAM,      0x80000000
  .equ RAMSIZE,  0x10000
  .equ DIVISOR,  10
  .equ MAGIC,    0x594C4157      // "WALY"

  .section .text.boot, "ax"
  .globl _start
_start:
  li    s0, UART
  li    s1, RAM
  li    s7, SPI

  // Straps from GPIO[5:0]; the inputs go through three synchronizer flops
  li    t0, GPIO
  li    t1, 0x3F
  sw    t1, GPIO_INPUT_EN(t0)
  nop
  nop
  nop
  nop
  lw    s6, GPIO_INPUT_VAL(t0)
  andi  t1, s6, 0x1F
  bnez  t1, 1f
  li    t1, DIVISOR
1:
  li    t0, 0x83                 // DLAB, 8 data bits, 1 stop bit, no parity
  sb    t0, UART_LCR(s0)
  sb    t1, UART_RBR(s0)         // DLL
  sb    zero, UART_DLM(s0)
  li    t0, 0x03
  sb    t0, UART_LCR(s0)

  andi  s6, s6, 0x20
  bnez  s6, uart

  // The flash: Read from address 0, with the chip select held for the whole transfer
  li    t0, 2
  sw    t0, SPI_CSMODE(s7)
  li    a0, 0x03
  jal   spi
  la    s9, spiread
  jal   spiread
  jal   spiread
  jal   spiread
  jal   getword
  li    t0, MAGIC
  bne   a0, t0, noflash
  jal   getword
  mv    s2, a0
  li    t0, RAMSIZE
  bgtu  s2, t0, noflash
  jal   load
  sw    zero, SPI_CSMODE(s7)
  li    a0, 'F'
  jal   putc
  j     run
noflash:
  sw    zero, SPI_CSMODE(s7)

uart:
  la    s9, getc
  li    a0, 'W'
  jal   putc
size:
  jal   getword
  mv    s2, a0
  li    t0, RAMSIZE
  bleu  s2, t0, 3f
  li    a0, '!'
  jal   putc
  j     size
3:
  jal   load
  andi  a0, s5, 0xFF
  jal   putc

  // Wait for the last byte to leave the transmitter before the program takes over the UART
run:
  lbu   t0, UART_LSR(s0)
  andi  t0, t0, 0x40             // transmitter empty
  beqz  t0, run
  li    sp, RAM + RAMSIZE
  jr    s1                       // no caches, so no fence.i (nor Zifencei)

// a0 = 4 bytes from the source s9, little endian
getword:
  mv    s10, ra
  li    s2, 0
  li    s3, 0                    // shift
2:
  jalr  s9
  sll   a0, a0, s3
  or    s2, s2, a0
  addi  s3, s3, 8
  li    t0, 32
  bne   s3, t0, 2b
  mv    a0, s2
  jr    s10

// s2 bytes from the source s9 into the RAM; s5 = their sum
load:
  mv    s11, ra
  mv    s3, s1                   // write pointer
  add   s4, s1, s2               // end
  li    s5, 0
4:
  beq   s3, s4, 5f
  jalr  s9
  sb    a0, 0(s3)
  add   s5, s5, a0
  addi  s3, s3, 1
  j     4b
5:
  jr    s11

// a0 = next byte from the flash
spiread:
  li    a0, 0
// send a0 on the SPI; a0 = the byte received meanwhile
spi:
  sw    a0, SPI_TXDATA(s7)
6:
  lw    a0, SPI_RXDATA(s7)
  bltz  a0, 6b
  andi  a0, a0, 0xFF
  ret

// a0 = next received byte
getc:
  lbu   t0, UART_LSR(s0)
  andi  t0, t0, 0x01
  beqz  t0, getc
  lbu   a0, UART_RBR(s0)
  ret

// send a0
putc:
  lbu   t0, UART_LSR(s0)
  andi  t0, t0, 0x20
  beqz  t0, putc
  sb    a0, UART_THR(s0)
  ret
