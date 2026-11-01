///////////////////////////////////////////
// main.c
//
// Purpose: DDR3 bring-up run by Wally itself (open-source FPGA flow, RV32
//          fpgaopensource).  Runs LiteX's own sdram_init() (JEDEC sequence and
//          read leveling, compiled from the installed LiteX sources) through
//          the LiteDRAM CSR window, then repeats a 64 KiB write/verify test of
//          the DDR3 forever, printing one line per pass.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
///////////////////////////////////////////

#include <stdint.h>
#include <stdio.h>
#include <liblitedram/sdram.h>

#define TEST_WORDS (0x10000 / 4)

static void uart_init(void) {
  // 16550 at UART_BASE, byte registers.  The UART divides its clock by
  // 2^UART_PRESCALE before the baud divisor.
  volatile uint8_t *uart = (volatile uint8_t *)UART_BASE;
  uint32_t clk = SYSTEMCLOCK >> UART_PRESCALE;
  uint32_t divisor = (clk + 8 * BAUD) / (16 * BAUD);
  uart[1] = 0x00;                    // IER: no interrupts
  uart[3] = 0x80;                    // LCR: DLAB
  uart[0] = divisor & 0xff;          // DLL
  uart[1] = (divisor >> 8) & 0xff;   // DLM
  uart[3] = 0x03;                    // LCR: 8N1
  uart[2] = 0xc7;                    // FCR: FIFOs on and cleared
}

int putchar(int c) {
  volatile uint8_t *uart = (volatile uint8_t *)UART_BASE;
  if (c == '\n') putchar('\r');
  while (!(uart[5] & 0x20)) ;        // LSR: THR empty
  uart[0] = (uint8_t)c;
  return c;
}

static uint32_t pattern(uint32_t pass, uint32_t i) {
  return (i * 0x9e3779b9u) ^ (pass * 0x85ebca6bu) ^ (i << 16);
}

int main(void) {
  uart_init();
  printf("\nddrinit: Wally runs the DDR3 initialization (CSRs at 0x%08lx)\n",
         (unsigned long)CSR_BASE);
  if (!sdram_init()) {
    printf("ddrinit: SDRAM initialization FAILED\n");
    return 1;
  }
  printf("ddrinit: SDRAM ready, testing 64 KiB at 0x%08lx\n", (unsigned long)MAIN_RAM_BASE);
  volatile uint32_t *ram = (volatile uint32_t *)MAIN_RAM_BASE;
  uint32_t total = 0;
  for (uint32_t pass = 1; ; pass++) {
    uint32_t errors = 0;
    for (uint32_t i = 0; i < TEST_WORDS; i++) ram[i] = pattern(pass, i);
    for (uint32_t i = 0; i < TEST_WORDS; i++) if (ram[i] != pattern(pass, i)) errors++;
    total += errors;
    printf("pass %lu errors %lu total %lu\n", (unsigned long)pass, (unsigned long)errors,
           (unsigned long)total);
  }
}
