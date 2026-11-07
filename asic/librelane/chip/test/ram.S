// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Test program for the 64 KiB RAM of the chip (eight 8 KiB banks of 2048 x 32 macros), loaded by the
// bootloader at 0x80000000 (bank 0): writes a different word into the first and the last word of every
// bank, reads them all back (a bank that aliased another, or one that is missing, shows), then checks
// the byte and halfword stores (the macros' write mask) in the top bank.  Sends 'P' on the UART if
// every check holds, else the digit of the first check that failed ('0' + n).

  .equ UART,     0x10000000
  .equ UART_THR, 0
  .equ UART_LSR, 5
  .equ RAM,      0x80000000
  .equ BANK,     0x2000

  .section .text
  .globl _start
_start:
  li    s0, UART
  li    s1, RAM

  li    t0, 1                         // bank 1 to 7: first and last word get bank-specific values
  li    t1, 8
write:
  slli  t2, t0, 13                    // bank * 0x2000
  add   t2, t2, s1
  li    t3, 0x5A5A0000
  add   t3, t3, t0                    // 0x5A5A000b
  sw    t3, 0(t2)
  not   t3, t3                        // 0xA5A5FFF4 (the complement)
  li    t4, BANK - 4
  add   t4, t4, t2
  sw    t3, 0(t4)
  addi  t0, t0, 1
  bne   t0, t1, write

  li    t0, 1
read:
  slli  t2, t0, 13
  add   t2, t2, s1
  li    t3, 0x5A5A0000
  add   t3, t3, t0
  lw    t5, 0(t2)
  li    a0, '1'
  bne   t5, t3, fail                  // 1: first word of a bank
  not   t3, t3
  li    t4, BANK - 4
  add   t4, t4, t2
  lw    t5, 0(t4)
  li    a0, '2'
  bne   t5, t3, fail                  // 2: last word of a bank
  addi  t0, t0, 1
  bne   t0, t1, read

  li    t2, RAM + 7 * BANK + 0x100    // byte and halfword stores in the top bank
  li    t3, -1
  sw    t3, 0(t2)
  li    t4, 0x12
  sb    t4, 1(t2)
  li    t4, 0x3456
  sh    t4, 2(t2)
  lw    t5, 0(t2)
  li    t3, 0x345612FF
  li    a0, '3'
  bne   t5, t3, fail                  // 3: byte and halfword stores
  sb    zero, 0(t2)
  lw    t5, 0(t2)
  li    t3, 0x34561200
  li    a0, '4'
  bne   t5, t3, fail                  // 4: a byte store clears only its byte

  li    t2, RAM + 8 * BANK - 4        // the very last word of the RAM
  li    t3, 0xC0DEF00D
  sw    t3, 0(t2)
  lw    t5, 0(t2)
  li    a0, '5'
  bne   t5, t3, fail

  li    a0, 'P'
fail:
done:
  lbu   t0, UART_LSR(s0)
  andi  t0, t0, 0x20
  beqz  t0, done
  sb    a0, UART_THR(s0)
1:
  j     1b
