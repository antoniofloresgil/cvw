// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Test program for the A extension of the chip, loaded by the bootloader at 0x80000000: the atomic
// memory operations and LR/SC on a word of the RAM, and misa.  Sends 'P' on the UART if every
// check holds, else the digit of the first check that failed.

  .equ UART,     0x10000000
  .equ UART_THR, 0
  .equ UART_LSR, 5

  .macro check reg, value, n          // fail with the digit n if reg != value
  li    t6, \value
  li    a0, '0' + \n
  bne   \reg, t6, fail
  .endm

  .section .text
  .globl _start
_start:
  li    s0, UART
  la    s1, word

  csrr  t0, misa                    // misa.A (bit 0)
  andi  t0, t0, 1
  check t0, 1, 0

  li    t0, 5
  sw    t0, 0(s1)
  li    t1, 3
  amoadd.w t2, t1, (s1)             // t2 = 5, word = 8
  check t2, 5, 1
  lw    t3, 0(s1)
  check t3, 8, 2

  li    t1, 0x10
  amoswap.w t2, t1, (s1)            // t2 = 8, word = 0x10
  check t2, 8, 3

  li    t1, 0x03
  amoor.w t2, t1, (s1)              // t2 = 0x10, word = 0x13
  amoand.w t2, t1, (s1)             // t2 = 0x13, word = 0x03
  check t2, 0x13, 4
  li    t1, 0x0F
  amoxor.w t2, t1, (s1)             // t2 = 3, word = 0x0C
  check t2, 3, 5

  li    t1, -2
  amomax.w t2, t1, (s1)             // signed: max(0x0C, -2) = 0x0C
  amomin.w t2, t1, (s1)             // signed: min(0x0C, -2) = -2
  lw    t3, 0(s1)
  check t3, -2, 6
  li    t1, 1
  amominu.w t2, t1, (s1)            // unsigned: min(0xFFFFFFFE, 1) = 1
  lw    t3, 0(s1)
  check t3, 1, 7
  li    t1, 0x7F
  amomaxu.w t2, t1, (s1)            // unsigned: max(1, 0x7F) = 0x7F
  lw    t3, 0(s1)
  check t3, 0x7F, 8

  lr.w  t2, (s1)                    // LR/SC: succeeds (t3 = 0), word = 0x80
  addi  t2, t2, 1
  sc.w  t3, t2, (s1)
  check t3, 0, 9
  lw    t4, 0(s1)
  check t4, 0x80, 10
  sc.w  t3, t2, (s1)                // no reservation: fails (t3 != 0), word unchanged
  seqz  t3, t3
  check t3, 0, 11
  lw    t4, 0(s1)
  check t4, 0x80, 12

  li    a0, 'P'
  j     done
fail:
done:
  lbu   t0, UART_LSR(s0)
  andi  t0, t0, 0x20
  beqz  t0, done
  sb    a0, UART_THR(s0)
1:
  j     1b

  .balign 4
word:
  .word 0
