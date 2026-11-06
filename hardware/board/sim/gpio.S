// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Test program for the board's GPIO pins (straps, buttons, LEDs), loaded by the bootloader at
// 0x80000000.  It sends 'G', then answers commands from the UART:
//   'R'        release the pins, read GPIO[7:0] and send the value
//   'L' value  drive value on GPIO[7:0] and send 'L'

  .equ UART,     0x10000000
  .equ UART_THR, 0
  .equ UART_RBR, 0
  .equ UART_LSR, 5
  .equ GPIO,     0x10060000
  .equ GPIO_INPUT_VAL, 0x00
  .equ GPIO_INPUT_EN,  0x04
  .equ GPIO_OUTPUT_EN, 0x08
  .equ GPIO_OUTPUT_VAL, 0x0C

  .section .text
  .globl _start
_start:
  li    s0, UART
  li    s1, GPIO
  li    a0, 'G'
  jal   putc
loop:
  jal   getc
  li    t0, 'R'
  beq   a0, t0, read
  li    t0, 'L'
  beq   a0, t0, drive
  j     loop

read:
  sw    zero, GPIO_OUTPUT_EN(s1)
  li    t0, 0xFF
  sw    t0, GPIO_INPUT_EN(s1)
  li    t1, 32                    // the inputs go through synchronizer flops
1:
  addi  t1, t1, -1
  bnez  t1, 1b
  lw    a0, GPIO_INPUT_VAL(s1)
  andi  a0, a0, 0xFF
  jal   putc
  j     loop

drive:
  jal   getc
  sw    a0, GPIO_OUTPUT_VAL(s1)
  sw    zero, GPIO_INPUT_EN(s1)
  li    t0, 0xFF
  sw    t0, GPIO_OUTPUT_EN(s1)
  li    a0, 'L'
  jal   putc
  j     loop

getc:
  lbu   t0, UART_LSR(s0)
  andi  t0, t0, 0x01
  beqz  t0, getc
  lbu   a0, UART_RBR(s0)
  ret

putc:
  lbu   t0, UART_LSR(s0)
  andi  t0, t0, 0x20
  beqz  t0, putc
  sb    a0, UART_THR(s0)
  ret
