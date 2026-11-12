/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * A 64 x 64 int8 fully connected layer through muRISCV-NN (muriscv_nn_fully_connected_s8, scalar kernel) on the chip's RV32IMAC, as TFLite
 * Micro would call it: input zero point, per-tensor Q31 multiplier and shift, output zero point, clamp to int8.  The output is checked
 * against an independent implementation of the same quantization (gemmlowp's rounding, written here with 64-bit integers), then the cycles of
 * the library call and of the library's requantization alone (the part that would stay in software if the unit returned the raw accumulator).
 * UART as the bootloader left it (115200 baud). */
#include <stdint.h>
#include "muriscv_nn_functions.h"
#include "muriscv_nn_support_functions.h"

#define UART_BASE 0x10000000UL
#define UART_THR  (*(volatile uint8_t *)(UART_BASE + 0))
#define UART_LSR  (*(volatile uint8_t *)(UART_BASE + 5))

#define IN   64
#define OUT  64
#define REPS 16

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

static int8_t  W[OUT * IN] __attribute__((aligned(4)));
static int8_t  X[IN] __attribute__((aligned(4)));
static int32_t BIAS[OUT];
static int8_t  Y[OUT], R[OUT];
static int32_t ACC[OUT];
static volatile int32_t sink;

static uint32_t seed = 12345;

static int8_t rnd8(void)
{
    seed ^= seed << 13;
    seed ^= seed >> 17;
    seed ^= seed << 5;
    return (int8_t)(seed >> 8);
}

/* independent requantization: round(acc * mult / 2^31) (ties away from zero), then a rounding right shift by -shift (ties away from zero);
 * a positive shift is a left shift of acc first (TFLite's convention) */
static int32_t requant_ref(int32_t acc, int32_t mult, int32_t shift)
{
    int64_t v = (int64_t)(shift > 0 ? ((int64_t)acc << shift) : acc);
    int64_t p = v * mult;
    int64_t r = p >= 0 ? (p + (1LL << 30)) >> 31 : -((-p + (1LL << 30)) >> 31);

    if (shift < 0) {
        int sh = -shift;
        int64_t half = 1LL << (sh - 1);
        r = r >= 0 ? (r + half) >> sh : -((-r + half) >> sh);
    }
    return (int32_t)r;
}

int main(void)
{
    const int32_t input_offset = 128, output_offset = -128, mult = 1431655765 /* 2/3 in Q31 */, shift = -6;

    puts_("muRISCV-NN fully connected s8 (scalar), 64 x 64\n");
    for (int j = 0; j < OUT; j++) {
        for (int i = 0; i < IN; i++) {
            W[j * IN + i] = rnd8();
        }
        BIAS[j] = rnd8() * 16;
    }
    for (int i = 0; i < IN; i++) {
        X[i] = rnd8();
    }

    muriscv_nn_context ctx = { .buf = 0, .size = 0 };
    muriscv_nn_fc_params fc = { .input_offset = input_offset, .filter_offset = 0, .output_offset = output_offset,
                                .activation = { .min = -128, .max = 127 } };
    muriscv_nn_per_tensor_quant_params q = { .multiplier = mult, .shift = shift };
    muriscv_nn_dims in_d = { .n = 1, .h = 1, .w = 1, .c = IN }, f_d = { .n = IN, .h = 1, .w = 1, .c = OUT },
                    b_d = { .n = 1, .h = 1, .w = 1, .c = OUT }, o_d = { .n = 1, .h = 1, .w = 1, .c = OUT };

    uint32_t buf_size = (uint32_t)muriscv_nn_fully_connected_s8_get_buffer_size(&f_d);
    puts_("library buffer: ");
    putu(buf_size);
    puts_(" bytes\n");

    muriscv_nn_status st = muriscv_nn_fully_connected_s8(&ctx, &fc, &q, &in_d, X, &f_d, W, &b_d, BIAS, &o_d, Y);

    int ok = st == MURISCV_NN_SUCCESS;

    for (int j = 0; j < OUT; j++) {
        int32_t acc = BIAS[j];
        for (int i = 0; i < IN; i++) {
            acc += (X[i] + input_offset) * W[j * IN + i];
        }
        ACC[j] = acc;
        int32_t v = requant_ref(acc, mult, shift) + output_offset;
        R[j] = (int8_t)(v > 127 ? 127 : v < -128 ? -128 : v);
        ok &= R[j] == Y[j];
    }
    puts_("library equals the independent reference: ");
    puts_(ok ? "yes\n" : "NO\n");

    uint32_t c0 = mcycle_();
    for (int k = 0; k < REPS; k++) {
        muriscv_nn_fully_connected_s8(&ctx, &fc, &q, &in_d, X, &f_d, W, &b_d, BIAS, &o_d, Y);
    }
    uint32_t c1 = mcycle_();
    int32_t s = 0;
    for (int k = 0; k < REPS; k++) {
        for (int j = 0; j < OUT; j++) {
            s += muriscv_nn_requantize(ACC[j] + k, mult, shift);
        }
    }
    uint32_t c2 = mcycle_();

    sink = s;

    puts_("layer: ");
    putu((c1 - c0) / REPS);
    puts_(" cycles per call; requantization of the 64 outputs alone: ");
    putu((c2 - c1) / REPS);
    puts_(" cycles (");
    putu((c2 - c1) / REPS / OUT);
    puts_(" per output)\n");
    puts_(ok ? "MNN FC OK\n" : "MNN FC FAIL\n");
    for (;;) {
    }
}
