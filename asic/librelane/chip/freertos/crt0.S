// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Start of the FreeRTOS image: the bootloader (../boot.S) has copied the image to 0x80000000, set sp
// at the top of the RAM and jumped here in Machine mode.  Clears .bss, points mtvec at FreeRTOS's trap
// handler and calls main.

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
  la    t0, freertos_risc_v_trap_handler    // the port does not set mtvec: traps and the tick go to it
  csrw  mtvec, t0
  call  main
3:
  j     3b
