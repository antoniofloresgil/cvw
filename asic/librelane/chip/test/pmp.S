// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Test program for the PMP of the chip, loaded by the bootloader at 0x80000000: the PMP CSRs, then
// User mode against three 1 KiB regions (code R+X, data R+W, read-only data) and a fourth with no
// entry, then a locked entry that stops Machine mode too.  Sends 'P' on the UART if every check
// holds, else the digit of the first check that failed ('0' + n).
//
// The trap handler counts faults in s3 and shifts their mcause into s2, so s2 = 0x751 after the
// three faults of the User code (store to the read-only region: 7, load from the unmapped region: 5,
// fetch from the data region: 1) and 0x7517 after the store Machine mode makes to the locked region.

  .option norvc                     // the handler skips a faulting instruction with mepc += 4

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
  li    s2, 0
  li    s3, 0

  csrr  t0, misa                    // misa.U (bit 20)
  srli  t0, t0, 20
  andi  t0, t0, 1
  check t0, 1, 0

  li    t0, 0x12345678              // pmpaddr15 and pmpcfg3 (entry 15) are implemented
  csrw  pmpaddr15, t0
  csrr  t1, pmpaddr15
  check t1, 0x12345678, 1
  li    t0, 0x1B000000
  csrw  pmpcfg3, t0
  csrr  t1, pmpcfg3
  check t1, 0x1B000000, 2
  csrw  pmpcfg3, zero               // entry 15 off again

  la    t0, handler
  csrw  mtvec, t0

  la    t0, _start                  // entry 0: code, 1 KiB NAPOT, R+X
  srli  t0, t0, 2
  ori   t0, t0, 0x7F
  csrw  pmpaddr0, t0
  la    t0, rwdata                  // entry 1: data, 1 KiB NAPOT, R+W
  srli  t0, t0, 2
  ori   t0, t0, 0x7F
  csrw  pmpaddr1, t0
  la    t0, rodata                  // entry 2: read-only data, 1 KiB NAPOT, R
  srli  t0, t0, 2
  ori   t0, t0, 0x7F
  csrw  pmpaddr2, t0
  li    t0, 0x00191B1D              // pmpcfg0: entry 2 = 0x19, entry 1 = 0x1B, entry 0 = 0x1D
  csrw  pmpcfg0, t0

  la    t0, u_code                  // to User mode
  csrw  mepc, t0
  li    t0, 3 << 11
  csrc  mstatus, t0
  mret

u_code:
  la    t1, rwdata
  li    t0, 0xA5
  sw    t0, 0(t1)                   // allowed
  lw    t2, 0(t1)
  la    t1, rodata
  lw    t3, 0(t1)                   // allowed
  sw    t0, 0(t1)                   // store access fault (7)
  la    t1, unmapped
  lw    t3, 0(t1)                   // no entry matches: load access fault (5); t3 keeps its value
  la    t1, rwdata
  jalr  ra, t1                      // fetch from a region without X: instruction access fault (1)
  ecall                             // back to Machine mode

handler:
  csrr  t5, mcause
  li    t6, 8                       // ecall from User mode: end of the User code
  beq   t5, t6, user_done
  slli  s2, s2, 4
  or    s2, s2, t5
  addi  s3, s3, 1
  li    t6, 1
  beq   t5, t6, fetch_fault
  csrr  t6, mepc                    // skip the faulting load or store
  addi  t6, t6, 4
  csrw  mepc, t6
  mret
fetch_fault:
  csrw  mepc, ra                    // return after the jalr
  mret
user_done:
  la    t5, machine
  csrw  mepc, t5
  li    t5, 3 << 11                 // return to Machine mode
  csrs  mstatus, t5
  mret

machine:
  check s3, 3, 3
  check s2, 0x751, 4
  check t2, 0xA5, 5                 // the User store to the data region happened
  check t3, 0x5A, 6                 // and the User load from the read-only region read it
  la    t1, rwdata
  lw    t4, 0(t1)
  check t4, 0xA5, 7
  la    t1, rodata
  lw    t4, 0(t1)                   // the faulting User store changed nothing
  check t4, 0x5A, 8

  li    t0, 0x00991B1D              // lock entry 2 (L | R): Machine mode is bound by it from now on
  csrw  pmpcfg0, t0
  la    t1, rodata
  li    t0, 0x77
  sw    t0, 0(t1)                   // store access fault (7) in Machine mode
  lw    t4, 0(t1)
  check t4, 0x5A, 9
  check s3, 4, 10
  check s2, 0x7517, 11

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

  .org  0x400                       // fails if the code outgrows its first 1 KiB region
  .org  0x400
rwdata:
  .word 0
  .org  0x800
rodata:
  .word 0x5A
  .org  0xC00
unmapped:
  .word 0
