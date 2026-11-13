/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * UART output (as the bootloader left it, 115200 baud), the cycle counter and a xorshift generator, shared by the programs of this directory. */
#ifndef MNN_COMMON_H
#define MNN_COMMON_H

#include <stdint.h>

#define UART_BASE 0x10000000UL
#define UART_THR  (*(volatile uint8_t *)(UART_BASE + 0))
#define UART_LSR  (*(volatile uint8_t *)(UART_BASE + 5))

static void putc_(char c)
{
    while ((UART_LSR & 0x20) == 0) {
    }
    UART_THR = (uint8_t)c;
}

static void puts_(const char *s)
{
    while (*s) {
        putc_(*s++);
    }
}

static void putu(uint32_t v)
{
    char d[10];
    int n = 0;

    do {
        d[n++] = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    while (n) {
        putc_(d[--n]);
    }
}

static inline uint32_t mcycle_(void)
{
    uint32_t c;

    __asm__ volatile("csrr %0, mcycle" : "=r"(c));
    return c;
}

static uint32_t seed = 12345;

static uint32_t rnd32(void)
{
    seed ^= seed << 13;
    seed ^= seed >> 17;
    seed ^= seed << 5;
    return seed;
}

static int8_t __attribute__((unused)) rnd8(void)
{
    return (int8_t)(rnd32() >> 8);
}

#endif
