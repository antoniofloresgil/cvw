// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Start of the FreeRTOS image: the bootloader (../boot.S) has copied the image to 0x80000000, set sp
// at the top of the RAM and jumped here in Machine mode.  Clears .bss, points mtvec at FreeRTOS's trap
// handler, locks the memory protection and calls main.

  .section .text.start
  .globl _start
_start:
  la    sp, __stack_top
  la    t0, __bss_start
  la    t1, __bss_end
1:
  bgeu  t0, t1, 2f
  sw    zero, 0(t0)
  addi  t0, t0, 4
  j     1b
2:
  // Static memory protection with three locked PMP entries, which bind Machine mode too and stay until
  // the next reset: the code and constants (RAM start to __text_end) are read and execute only, the rest
  // of the RAM (data, heap, stacks) read and write only.  A write to the code or a jump into the data,
  // the heap or a stack is a store or instruction access fault.  Entry 0 (off) is the lower bound of
  // the TOR entry 1; the peripherals match no entry, so Machine mode reaches them as before.
  la    t0, __ram_start
  srli  t0, t0, 2
  csrw  pmpaddr0, t0
  la    t0, __text_end
  srli  t0, t0, 2
  csrw  pmpaddr1, t0
  la    t0, __stack_top             // the end of the RAM
  srli  t0, t0, 2
  csrw  pmpaddr2, t0
  li    t0, 0x008B8D00              // entry 2: L | TOR | R | W; entry 1: L | TOR | R | X; entry 0: off
  csrw  pmpcfg0, t0

  la    t0, freertos_risc_v_trap_handler    // the port does not set mtvec: traps and the tick go to it
  csrw  mtvec, t0
  call  main
3:
  j     3b
