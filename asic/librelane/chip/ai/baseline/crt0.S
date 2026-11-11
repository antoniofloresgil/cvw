// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Start of the baseline image: the bootloader (../../boot.S) has copied it to 0x80000000 and jumped here in Machine mode.
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
  call  main
3:
  j     3b
