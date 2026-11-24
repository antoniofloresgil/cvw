#include "system.h"

PERIOD = (SYSTEMCLOCK / 2)
CLINT_MSIP = 0x02000000          # the CLINT's software interrupt pending register of hart 0; hart h at + 4h

.section .init
.global _start
.type _start, @function


_start:
  # Initialize global pointer
  .option push
  .option norelax
  1:auipc gp, %pcrel_hi(__global_pointer$)
  addi  gp, gp, %pcrel_lo(1b)
  .option pop

  # Harts other than 0 wait in parkHart while hart 0 loads the card
  csrr t0, mhartid
  bnez t0, parkHart

  li x1, 0
  li x2, 0
  li x4, 0
  li x5, 0
  li x6, 0
  li x7, 0
  li x8, 0
  li x9, 0
  li x10, 0
  li x11, 0
  li x12, 0
  li x13, 0
  li x14, 0
  li x15, 0
  li x16, 0
  li x17, 0
  li x18, 0
  li x19, 0
  li x20, 0
  li x21, 0
  li x22, 0
  li x23, 0
  li x24, 0
  li x25, 0
  li x26, 0
  li x27, 0
  li x28, 0
  li x29, 0
  li x30, 0
  li x31, 0


  # set the stack pointer to the top of memory - 8 bytes (pointer size)
  li sp, (EXT_MEM_END - 8)

  li a0, 0x00000000
  li a1, EXT_MEM_BASE
  #li a2, 128*1024*1024/512 # copy 128MB
  li a2, 127*1024*1024/512 # copy 127MB upper 1MB contains the return address (ra)
  #li a2, 800 # copy 400KB
  jal ra, copyFlash

  fence.i
  # now toggle led so we know the copy completed.

  # write to gpio
  li t2, 0xFF
  la t3, 0x1006000C
  li t4, 5

loop:

  # delay
  li t0, PERIOD/2
delay1:
  addi t0, t0, -1
  bge t0, x0, delay1
  sw t2, 0x0(t3)

  li t0, PERIOD/2
delay2:
  addi t0, t0, -1
  bge t0, x0, delay2
  sw x0, 0x0(t3)

  addi t4, t4, -1
  bgt t4, x0, loop


  # now that the card is copied and the led toggled we
  # jump to the copied contents of the sd card.

#if NHARTS > 1
  # wake the other harts: a software interrupt to each
  li t1, CLINT_MSIP + 4
  li t2, 1
  li t3, NHARTS - 1
wakeHarts:
  sw t2, 0(t1)
  addi t1, t1, 4
  addi t3, t3, -1
  bnez t3, wakeHarts
#endif

jumpToLinux:
  csrrs a0, 0xF14, x0   # copy hart ID to a0
  li a1, FDT_ADDRESS  # This is the device tree address
  la a2, end_of_bios
  li t0, EXT_MEM_BASE  # start of code

  jalr x0, t0, 0

  # A hart other than 0 sleeps until hart 0's software interrupt (wakeHarts), clears it and enters the program
  # of the card (OpenSBI) as hart 0 does, with its hart ID in a0 and the device tree in a1
parkHart:
  li t1, 8              # mie.MSIE: wfi returns on the software interrupt (mstatus.MIE stays 0: no trap)
  csrw mie, t1
1:
  wfi
  csrr t1, mip
  andi t1, t1, 8
  beqz t1, 1b
  li t1, CLINT_MSIP
  slli t2, t0, 2
  add t1, t1, t2
  sw x0, 0(t1)
  csrw mie, x0
  fence.i
  mv a0, t0
  li a1, FDT_ADDRESS
  li t0, EXT_MEM_BASE
  jalr x0, t0, 0

end_of_bios:
