// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Test program for the board's I2C bus (GPIO6 SCL, GPIO7 SDA), loaded by the bootloader at
// 0x80000000.  It scans six addresses, then reads and writes the four devices, and sends what it
// found on the UART, raw bytes after a letter:
//   S  six characters: '1' if 0x48 0x49 0x50 0x51 0x60 0x61 acknowledged its address, else '0'
//   T  the TMP102's temperature register (pointer write, STOP, then a read): two bytes
//   E  the 24LC256: writes 0xA5 at 0x0123, sets the address again and reads it back: one byte
//   A  the ADS1115's configuration register (pointer write, repeated START, read): two bytes
//   D  the MCP4725: a fast-mode write of 0x0ABC, and a read of its status byte and DAC register
//   Z  done

  .equ UART,     0x10000000
  .equ UART_THR, 0
  .equ UART_LSR, 5
  .equ GPIO,     0x10060000
  .equ GPIO_IOF_EN,  0x38
  .equ GPIO_IOF_SEL, 0x3C
  .equ I2C,      0x10082000

  .equ START, 0x01
  .equ STOP,  0x02
  .equ READ,  0x04
  .equ WRITE, 0x08
  .equ NACK,  0x10

  .section .text
  .globl _start
_start:
  li    s0, UART
  li    s1, GPIO
  li    s3, I2C
  li    t0, 0xC0                  // GPIO6 and GPIO7 take alternate function 1: I2C
  sw    t0, GPIO_IOF_EN(s1)
  sw    t0, GPIO_IOF_SEL(s1)
  li    t0, 11                    // SCL period 4 * 12 clocks: 384 kHz at 18.432 MHz
  sw    t0, 0x00(s3)
  li    t0, 1
  sw    t0, 0x04(s3)

  li    a0, 'S'
  jal   putc
  la    s5, addrs
  la    s6, addrs_end
1:
  lbu   a0, 0(s5)
  slli  a0, a0, 1
  li    a1, START | WRITE | STOP
  jal   i2c
  li    a0, '1'
  sub   a0, a0, a1                // a1 = 1 if not acknowledged
  jal   putc
  addi  s5, s5, 1
  bne   s5, s6, 1b

  // TMP102 at 0x48: pointer 0, STOP, then START, read two bytes
  li    a0, 'T'
  jal   putc
  li    a0, 0x90
  li    a1, START | WRITE
  jal   i2c
  li    a0, 0x00
  li    a1, WRITE | STOP
  jal   i2c
  li    a0, 0x91
  li    a1, START | WRITE
  jal   i2c
  li    a1, READ
  jal   i2c
  jal   putc
  li    a1, READ | NACK | STOP
  jal   i2c
  jal   putc

  // 24LC256 at 0x50: write 0xA5 at 0x0123, then set the address again and read it
  li    a0, 'E'
  jal   putc
  li    a0, 0xA0
  li    a1, START | WRITE
  jal   i2c
  li    a0, 0x01
  li    a1, WRITE
  jal   i2c
  li    a0, 0x23
  li    a1, WRITE
  jal   i2c
  li    a0, 0xA5
  li    a1, WRITE | STOP
  jal   i2c
  li    a0, 0xA0
  li    a1, START | WRITE
  jal   i2c
  li    a0, 0x01
  li    a1, WRITE
  jal   i2c
  li    a0, 0x23
  li    a1, WRITE
  jal   i2c
  li    a0, 0xA1                  // repeated START, read
  li    a1, START | WRITE
  jal   i2c
  li    a1, READ | NACK | STOP
  jal   i2c
  jal   putc

  // ADS1115 at 0x49: pointer 1 (configuration), repeated START, read two bytes
  li    a0, 'A'
  jal   putc
  li    a0, 0x92
  li    a1, START | WRITE
  jal   i2c
  li    a0, 0x01
  li    a1, WRITE
  jal   i2c
  li    a0, 0x93
  li    a1, START | WRITE
  jal   i2c
  li    a1, READ
  jal   i2c
  jal   putc
  li    a1, READ | NACK | STOP
  jal   i2c
  jal   putc

  // MCP4725 at 0x60: fast-mode write of 0x0ABC, then read status and the DAC register
  li    a0, 'D'
  jal   putc
  li    a0, 0xC0
  li    a1, START | WRITE
  jal   i2c
  li    a0, 0x0A
  li    a1, WRITE
  jal   i2c
  li    a0, 0xBC
  li    a1, WRITE | STOP
  jal   i2c
  li    a0, 0xC1
  li    a1, START | WRITE
  jal   i2c
  li    a1, READ
  jal   i2c
  jal   putc
  li    a1, READ
  jal   i2c
  jal   putc
  li    a1, READ | NACK | STOP
  jal   i2c
  jal   putc

  li    a0, 'Z'
  jal   putc
2:
  j     2b

// a0 = byte to send, a1 = command; returns a0 = the byte received, a1 = 1 if the last byte written
// was not acknowledged
i2c:
  sw    a0, 0x08(s3)
  sw    a1, 0x0C(s3)
3:
  lw    t0, 0x10(s3)
  andi  t1, t0, 1                 // BUSY
  bnez  t1, 3b
  lw    a0, 0x08(s3)
  andi  a0, a0, 0xFF
  srli  a1, t0, 1
  andi  a1, a1, 1                 // RXACK
  ret

putc:
  lbu   t0, UART_LSR(s0)
  andi  t0, t0, 0x20
  beqz  t0, putc
  sb    a0, UART_THR(s0)
  ret

addrs:
  .byte 0x48, 0x49, 0x50, 0x51, 0x60, 0x61
addrs_end:
