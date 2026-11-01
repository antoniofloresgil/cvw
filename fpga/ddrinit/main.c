///////////////////////////////////////////
// main.c
//
// Purpose: DDR3 bring-up run by Wally itself (open-source FPGA flow: RV32
//          fpgaopensource, and stage 0 of RV64 fpganexysvideoopen).  Runs LiteX's own sdram_init() (JEDEC sequence and
//          read leveling, compiled from the installed LiteX sources) through
//          the LiteDRAM CSR window, then repeats a 64 KiB write/verify test of
//          the DDR3 forever, printing one line per pass.  Built as stage 0 of
//          the RV64 boot (DDRINIT_NEXT), it runs one pass and jumps to the ZSBL.
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
#ifdef DDRINIT_SKIP
  // The LiteDRAM service CPU has already initialized the DDR3; only test it.
  printf("\nddrinit: DDR3 initialized by the service CPU\n");
#else
  printf("\nddrinit: Wally runs the DDR3 initialization (CSRs at 0x%08lx)\n",
         (unsigned long)CSR_BASE);
  if (!sdram_init()) {
    printf("ddrinit: SDRAM initialization FAILED\n");
    return 1;
  }
#endif
  printf("ddrinit: SDRAM ready, testing 64 KiB at 0x%08lx\n", (unsigned long)MAIN_RAM_BASE);
  volatile uint32_t *ram = (volatile uint32_t *)MAIN_RAM_BASE;
  uint32_t total = 0;
#ifdef DDRINIT_NEXT
  // Stage 0 of a boot chain: one test pass, then hand over to the next stage
  // (the ZSBL), or stop if the DDR3 is not usable.
  for (uint32_t i = 0; i < TEST_WORDS; i++) ram[i] = pattern(1, i);
  for (uint32_t i = 0; i < TEST_WORDS; i++) if (ram[i] != pattern(1, i)) total++;
  if (total) {
    printf("ddrinit: %lu errors, not booting\n", (unsigned long)total);
    return 1;
  }
  printf("ddrinit: no errors, jumping to 0x%08lx\n", (unsigned long)DDRINIT_NEXT);
  // The next stage resets the UART and its FIFOs: let the transmitter drain.
  while (!(((volatile uint8_t *)UART_BASE)[5] & 0x40)) ;   // LSR: TEMT
  ((void (*)(void))DDRINIT_NEXT)();
#endif
  for (uint32_t pass = 1; ; pass++) {
    uint32_t errors = 0;
    for (uint32_t i = 0; i < TEST_WORDS; i++) ram[i] = pattern(pass, i);
    for (uint32_t i = 0; i < TEST_WORDS; i++) if (ram[i] != pattern(pass, i)) errors++;
    total += errors;
    printf("pass %lu errors %lu total %lu\n", (unsigned long)pass, (unsigned long)errors,
           (unsigned long)total);
  }
}
