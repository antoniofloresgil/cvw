// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Test program for the MCU peripherals of the chip (src/uncore/mcu), loaded by the bootloader at
// 0x80000000.  The pins are GPIO alternate function 1: the timer's channels 0-3 on GPIO 0-3, I2C
// SCL and SDA on GPIO 6 and 7.  Progress goes out on the UART, one letter each:
//   T  the timer runs: PWM 25 % on GPIO0, 75 % on GPIO1; channel 2 waits for a rising edge on GPIO2
//   C  that edge was captured
//   I  an I2C device at 0x50 acknowledged a write of 0x5A;  n: it did not
//   R  a read from it returned 0xC3;  r: another value
//   A  the RTC's alarm fired
//   D  the watchdog is enabled and not kicked: the chip must reset (the pads are released first)

  .equ UART,     0x10000000
  .equ UART_THR, 0
  .equ UART_LSR, 5
  .equ GPIO,     0x10060000
  .equ GPIO_IOF_EN,  0x38
  .equ GPIO_IOF_SEL, 0x3C
  .equ TIMER,    0x10080000
  .equ WDT,      0x10081000
  .equ I2C,      0x10082000
  .equ RTC,      0x10083000

  .section .text
  .globl _start
_start:
  li    s0, UART
  li    s1, GPIO
  li    s2, TIMER
  li    s3, I2C
  li    s4, RTC
  li    s5, WDT

  li    t0, 0xCF                  // GPIO 0-3 and 6-7 take alternate function 1
  sw    t0, GPIO_IOF_EN(s1)
  sw    t0, GPIO_IOF_SEL(s1)

  li    t0, 99                    // timer: counts 0..99
  sw    t0, 0x08(s2)
  li    t0, 25
  sw    t0, 0x20(s2)              // channel 0: high while CNT < 25
  li    t0, 75
  sw    t0, 0x24(s2)              // channel 1: high while CNT < 75
  li    t0, 3
  sw    t0, 0x48(s2)              // channel 2: capture, rising edge
  li    t0, 1
  sw    t0, 0x00(s2)              // enable
  li    a0, 'T'
  jal   putc
1:
  lw    t0, 0x10(s2)              // STATUS: channel 2 bit
  andi  t0, t0, 0x08
  beqz  t0, 1b
  lw    t1, 0x28(s2)              // the captured count
  li    a0, 'C'
  jal   putc

  li    t0, 3                     // I2C: 4 clocks per step
  sw    t0, 0x00(s3)
  li    t0, 1
  sw    t0, 0x04(s3)
  li    t0, 0xA0                  // START, address 0x50 + write
  sw    t0, 0x08(s3)
  li    t0, 0x09
  sw    t0, 0x0C(s3)
  jal   i2cwait
  li    t0, 0x5A                  // WRITE + STOP
  sw    t0, 0x08(s3)
  li    t0, 0x0A
  sw    t0, 0x0C(s3)
  jal   i2cwait
  lw    t0, 0x10(s3)
  andi  t0, t0, 0x02              // RXACK: no acknowledge
  li    a0, 'I'
  beqz  t0, 2f
  li    a0, 'n'
2:
  jal   putc
  li    t0, 0xA1                  // START, address 0x50 + read
  sw    t0, 0x08(s3)
  li    t0, 0x09
  sw    t0, 0x0C(s3)
  jal   i2cwait
  li    t0, 0x16                  // READ + NACK + STOP
  sw    t0, 0x0C(s3)
  jal   i2cwait
  lw    t0, 0x08(s3)
  li    t1, 0xC3
  li    a0, 'R'
  beq   t0, t1, 3f
  li    a0, 'r'
3:
  jal   putc

  li    t0, 3                     // RTC: a tick every 4 clocks, alarm at 10
  sw    t0, 0x04(s4)
  li    t0, 10
  sw    t0, 0x0C(s4)
  li    t0, 1
  sw    t0, 0x00(s4)
4:
  lw    t0, 0x10(s4)
  andi  t0, t0, 1
  beqz  t0, 4b
  li    a0, 'A'
  jal   putc

  sw    zero, GPIO_IOF_EN(s1)     // release the pads, then arm the watchdog and let it expire
  sw    zero, 0x00(s2)
  li    t0, 2000
  sw    t0, 0x04(s5)
  li    t0, 1
  sw    t0, 0x00(s5)
  li    a0, 'D'
  jal   putc
5:
  j     5b

i2cwait:
  lw    t0, 0x10(s3)
  andi  t0, t0, 1                 // BUSY
  bnez  t0, i2cwait
  ret

putc:
  lbu   t0, UART_LSR(s0)
  andi  t0, t0, 0x20
  beqz  t0, putc
  sb    a0, UART_THR(s0)
  ret
