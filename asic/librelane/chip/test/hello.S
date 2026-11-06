// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Test program for the chip, loaded by the bootloader at 0x80000000: prints "OK\n" on the UART
// (whose divisor the bootloader has set) and drives 6 * 7 on GPIO[7:0].

  .equ UART,     0x10000000
  .equ UART_THR, 0
  .equ UART_LSR, 5
  .equ GPIO,     0x10060000
  .equ GPIO_OUTPUT_EN,  0x08
  .equ GPIO_OUTPUT_VAL, 0x0C

  .section .text
  .globl _start
_start:
  li    s0, UART
  li    a0, 'O'
  jal   putc
  li    a0, 'K'
  jal   putc
  li    a0, '\n'
  jal   putc
  li    t0, GPIO
  li    t1, 6
  li    t2, 7
  mul   t1, t1, t2
  sw    t1, GPIO_OUTPUT_VAL(t0)
  li    t1, 0xFF
  sw    t1, GPIO_OUTPUT_EN(t0)
1:
  j     1b

putc:
  lbu   t0, UART_LSR(s0)
  andi  t0, t0, 0x20
  beqz  t0, putc
  sb    a0, UART_THR(s0)
  ret
