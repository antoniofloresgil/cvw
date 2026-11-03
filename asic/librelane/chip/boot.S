// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Bootloader of asic_soc_rv32imc, in its 512-byte BOOTROM at 0x1000: loads a program over the
// UART into the RAM at 0x80000000 and runs it.
//
// Protocol (8 data bits, no parity, 1 stop bit):
//   chip -> host  'W'                      ready
//   host -> chip  size, 4 bytes, little endian (at most 4096)
//   host -> chip  size bytes of the program, loaded at 0x80000000
//   chip -> host  8-bit sum of those bytes; then the chip jumps to 0x80000000 with sp at the top
//                 of the RAM.  A size over 4096 sends back '!' and waits for a new size.
// Baud rate: f_clk / (16 * divisor), with the divisor read from GPIO[7:0] at reset, or 18 if they
// read 0 (115200 baud with a 33.3 MHz clock, 0.5 % off).

  .equ UART,     0x10000000      // PC16550D, one register per byte
  .equ UART_RBR, 0               // receive buffer (DLL with LCR.DLAB)
  .equ UART_THR, 0               // transmit holding
  .equ UART_DLM, 1               // divisor latch MSB, with LCR.DLAB
  .equ UART_LCR, 3
  .equ UART_LSR, 5               // bit 0: data ready, bit 5: transmit holding empty
  .equ GPIO,     0x10060000
  .equ GPIO_INPUT_VAL, 0x00
  .equ GPIO_INPUT_EN,  0x04
  .equ RAM,      0x80000000
  .equ RAMSIZE,  0x1000
  .equ DIVISOR,  18

  .section .text.boot, "ax"
  .globl _start
_start:
  li    s0, UART
  li    s1, RAM

  // Baud rate divisor from GPIO[7:0]; the inputs go through three synchronizer flops
  li    t0, GPIO
  li    t1, 0xFF
  sw    t1, GPIO_INPUT_EN(t0)
  nop
  nop
  nop
  nop
  lw    t1, GPIO_INPUT_VAL(t0)
  andi  t1, t1, 0xFF
  bnez  t1, 1f
  li    t1, DIVISOR
1:
  li    t0, 0x83                 // DLAB, 8 data bits, 1 stop bit, no parity
  sb    t0, UART_LCR(s0)
  sb    t1, UART_RBR(s0)         // DLL
  sb    zero, UART_DLM(s0)
  li    t0, 0x03
  sb    t0, UART_LCR(s0)

  li    a0, 'W'
  jal   putc

size:
  li    s2, 0                    // size, little endian
  li    s3, 0                    // shift
2:
  jal   getc
  sll   a0, a0, s3
  or    s2, s2, a0
  addi  s3, s3, 8
  li    t0, 32
  bne   s3, t0, 2b
  li    t0, RAMSIZE
  bleu  s2, t0, 3f
  li    a0, '!'
  jal   putc
  j     size

3:
  mv    s3, s1                   // write pointer
  add   s4, s1, s2               // end
  li    s5, 0                    // sum
4:
  beq   s3, s4, 5f
  jal   getc
  sb    a0, 0(s3)
  add   s5, s5, a0
  addi  s3, s3, 1
  j     4b
5:
  andi  a0, s5, 0xFF
  jal   putc
  // Wait for the sum to leave the transmitter before the program takes over the UART
6:
  lbu   t0, UART_LSR(s0)
  andi  t0, t0, 0x40             // transmitter empty
  beqz  t0, 6b
  li    sp, RAM + RAMSIZE
  jr    s1                       // no caches, so no fence.i (nor Zifencei)

// a0 = next received byte
getc:
  lbu   t0, UART_LSR(s0)
  andi  t0, t0, 0x01
  beqz  t0, getc
  lbu   a0, UART_RBR(s0)
  ret

// send a0
putc:
  lbu   t0, UART_LSR(s0)
  andi  t0, t0, 0x20
  beqz  t0, putc
  sb    a0, UART_THR(s0)
  ret
