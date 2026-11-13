/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Test of the AI unit (src/uncore/ai) on a chip built with AI_SUPPORTED (asic_soc_rv32imac_ai): the unit's matrix-vector products against
 * a reference in C, bit by bit; the arguments it must refuse; and the cycles it takes, from its own counter and from mcycle.
 * It prints one line per case and "AI GEMV OK" if all passed. */
#include <stdint.h>

#define UART_BASE 0x10000000UL
#define UART_THR  (*(volatile uint8_t *)(UART_BASE + 0))
#define UART_LSR  (*(volatile uint8_t *)(UART_BASE + 5))

#define AI_BASE   0x10084000UL
#define AI(off)   (*(volatile uint32_t *)(AI_BASE + (off)))
#define AI_CTRL   0x00
#define AI_STATUS 0x04
#define AI_IN     0x08
#define AI_OUT    0x0C
#define AI_W      0x10
#define AI_X      0x14
#define AI_BIAS   0x18
#define AI_Y      0x1C
#define AI_MULT   0x20
#define AI_SHIFT  0x24
#define AI_CYCLES 0x28
#define CTRL_START 1u
#define CTRL_RELU  2u
#define CTRL_RAW   4u
#define CTRL_Q31   8u
#define CTRL_W4    16u

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

static inline uint32_t rdcycle(void)
{
    uint32_t c;

    __asm__ volatile("csrr %0, mcycle" : "=r"(c));
    return c;
}

static int8_t W[64 * 64] __attribute__((aligned(4)));
static int8_t WB[3 * 1024] __attribute__((aligned(4)));
static int8_t X[1024] __attribute__((aligned(4)));
static int32_t BIAS[64] __attribute__((aligned(4)));
static int8_t Y[72] __attribute__((aligned(4)));    /* the unit writes the first OUT bytes; the others stay at 0x55 */
static int8_t R[72] __attribute__((aligned(4)));
static int32_t YW[72] __attribute__((aligned(4)));  /* RAW mode: the unit writes the first OUT words; the others stay at the canary */
static int32_t RW[72];
#define CANARY 0x55555555

static uint32_t seed = 12345;

static int8_t rnd8(void)
{
    seed ^= seed << 13;
    seed ^= seed >> 17;
    seed ^= seed << 5;
    return (int8_t)(seed >> 8);
}

static int8_t requant(int32_t acc, int32_t bias, int32_t mult, int shift, int relu)
{
    int64_t v = ((int64_t)(acc + bias) * mult) >> shift;
    int64_t lo = relu ? 0 : -128;

    if (v > 127) {
        v = 127;
    }
    if (v < lo) {
        v = lo;
    }
    return (int8_t)v;
}

static void reference(const int8_t *w, int in, int out, const int32_t *bias, int mult, int shift, int relu)
{
    for (int j = 0; j < out; j++) {
        int32_t acc = 0;

        for (int i = 0; i < in; i++) {
            acc += w[j * in + i] * X[i];
        }
        R[j] = requant(acc, bias ? bias[j] : 0, mult, shift, relu);
    }
}

/* run the unit; returns the STATUS read at the end and the unit's cycles and the core's in *cyc */
static uint32_t run(const int8_t *w, int in, int out, const int32_t *bias, int mult, int shift, int relu, int raw, uint32_t *cyc)
{
    for (int i = 0; i < 72; i++) {
        Y[i] = 0x55;
        YW[i] = CANARY;
    }
    AI(AI_IN) = (uint32_t)in;
    AI(AI_OUT) = (uint32_t)out;
    AI(AI_W) = (uint32_t)(uintptr_t)w;
    AI(AI_X) = (uint32_t)(uintptr_t)X;
    AI(AI_BIAS) = (uint32_t)(uintptr_t)bias;
    AI(AI_Y) = raw ? (uint32_t)(uintptr_t)YW : (uint32_t)(uintptr_t)Y;
    AI(AI_MULT) = (uint32_t)mult;
    AI(AI_SHIFT) = (uint32_t)shift;
    uint32_t c0 = rdcycle();

    AI(AI_CTRL) = CTRL_START | (relu ? CTRL_RELU : 0u) | (raw ? CTRL_RAW : 0u);
    uint32_t st;

    do {
        st = AI(AI_STATUS);
    } while (st & 1u);
    cyc[1] = rdcycle() - c0;
    cyc[0] = AI(AI_CYCLES);
    AI(AI_STATUS) = 6u;     /* clear DONE and ERROR */
    return st;
}

static int check(const char *name, const int8_t *w, int in, int out, const int32_t *bias, int mult, int shift, int relu)
{
    uint32_t cyc[2];
    uint32_t st = run(w, in, out, bias, mult, shift, relu, 0, cyc);
    int ok = (st & 6u) == 2u;       /* DONE, no ERROR */

    reference(w, in, out, bias, mult, shift, relu);
    for (int j = 0; j < out; j++) {
        ok &= Y[j] == R[j];
    }
    for (int j = out; j < 72; j++) {
        ok &= Y[j] == 0x55;         /* nothing written beyond OUT */
    }
    puts_(name);
    puts_(ok ? " ok " : " FAIL ");
    putu(cyc[0]);
    puts_(" unit cycles, ");
    putu(cyc[1]);
    puts_(" core cycles\n");
    return ok;
}

/* RAW mode: the int32 accumulator W x + bias; MULT, SHIFT and RELU must be ignored (the values passed would be refused or would change a byte result) */
static int check_raw(const char *name, const int8_t *w, int in, int out, const int32_t *bias)
{
    uint32_t cyc[2];
    uint32_t st = run(w, in, out, bias, 0, 99, 1, 1, cyc);
    int ok = (st & 6u) == 2u;

    for (int j = 0; j < out; j++) {
        int32_t acc = bias ? bias[j] : 0;

        for (int i = 0; i < in; i++) {
            acc += w[j * in + i] * X[i];
        }
        RW[j] = acc;
        ok &= YW[j] == acc;
    }
    for (int j = out; j < 72; j++) {
        ok &= YW[j] == CANARY;
    }
    for (int j = 0; j < 72; j++) {
        ok &= Y[j] == 0x55;         /* the byte buffer was not touched */
    }
    puts_(name);
    puts_(ok ? " ok " : " FAIL ");
    putu(cyc[0]);
    puts_(" unit cycles, ");
    putu(cyc[1]);
    puts_(" core cycles\n");
    return ok;
}

static uint32_t xover;      /* a source address of x for the next refuse_ctrl, 0 for the usual X */

static int refuse_ctrl(const char *name, uint32_t in, uint32_t out, uint32_t wa, uint32_t ya, uint32_t shift, uint32_t ctrl)
{
    for (int i = 0; i < 72; i++) {
        Y[i] = 0x55;
    }
    AI(AI_IN) = in;
    AI(AI_OUT) = out;
    AI(AI_W) = wa;
    AI(AI_X) = xover ? xover : (uint32_t)(uintptr_t)X;
    AI(AI_BIAS) = 0;
    AI(AI_Y) = ya;
    AI(AI_MULT) = 1;
    AI(AI_SHIFT) = shift;
    AI(AI_CTRL) = ctrl;
    uint32_t st = AI(AI_STATUS);

    AI(AI_STATUS) = 6u;
    int ok = (st & 7u) == 4u;       /* ERROR only: not busy, not done */

    for (int i = 0; i < 72; i++) {
        ok &= Y[i] == 0x55;
    }
    puts_(name);
    puts_(ok ? " refused\n" : " NOT REFUSED\n");
    return ok;
}

static int refuse(const char *name, uint32_t in, uint32_t out, uint32_t wa, uint32_t ya, uint32_t shift)
{
    return refuse_ctrl(name, in, out, wa, ya, shift, CTRL_START);
}

int main(void)
{
    int ok = 1;

    puts_("AI unit test\n");
    for (int i = 0; i < 64 * 64; i++) {
        W[i] = rnd8();
    }
    for (int i = 0; i < 3 * 1024; i++) {
        WB[i] = rnd8();
    }
    for (int i = 0; i < 1024; i++) {
        X[i] = rnd8();
    }
    for (int i = 0; i < 64; i++) {
        BIAS[i] = rnd8() * 16;
    }
    ok &= check("layer 64x64 relu", W, 64, 64, BIAS, 77, 14, 1);
    ok &= check("layer 64x64 again", W, 64, 64, BIAS, 77, 14, 1);
    ok &= check("7x12 signed no bias", W, 12, 7, 0, 300, 6, 0);
    ok &= check("5x4 signed", W, 4, 5, BIAS, -3, 2, 0);
    ok &= check("1x4 relu", W, 4, 1, BIAS, 1000, 20, 1);
    ok &= check("63x64 bias", W, 64, 63, BIAS, 123, 12, 0);
    ok &= check("3x1024", WB, 1024, 3, BIAS, 5, 16, 0);
    ok &= check("64x64 shift 0 saturates", W, 64, 64, BIAS, 32767, 0, 0);
    ok &= check("64x64 shift 47", W, 64, 64, BIAS, -32768, 47, 0);

    ok &= refuse("IN not a multiple of 4", 6, 4, (uint32_t)(uintptr_t)W, (uint32_t)(uintptr_t)Y, 8);
    ok &= refuse("IN zero", 0, 4, (uint32_t)(uintptr_t)W, (uint32_t)(uintptr_t)Y, 8);
    ok &= refuse("IN too long", 1028, 1, (uint32_t)(uintptr_t)WB, (uint32_t)(uintptr_t)Y, 8);
    ok &= refuse("OUT zero", 4, 0, (uint32_t)(uintptr_t)W, (uint32_t)(uintptr_t)Y, 8);
    ok &= refuse("shift 48", 4, 4, (uint32_t)(uintptr_t)W, (uint32_t)(uintptr_t)Y, 48);
    ok &= refuse("W in the boot ROM", 4, 4, 0x1000, (uint32_t)(uintptr_t)Y, 8);
    ok &= refuse("W past the usable RAM", 4, 4, 0x8000DFFC, (uint32_t)(uintptr_t)Y, 8);
    /* the part of the RAM that holds the unit's input area (0x8000C000-0x8000DFFF, its macro has one port, which the unit uses for x): W and the
     * source of x must lie below it, y below the area itself (the last 1 KiB, 0x8000DC00) */
    ok &= refuse("W in the input area's RAM part", 4, 4, 0x8000C000, (uint32_t)(uintptr_t)Y, 8);
    xover = 0x8000C000;
    ok &= refuse("x in the input area's RAM part", 4, 4, (uint32_t)(uintptr_t)W, (uint32_t)(uintptr_t)Y, 8);
    xover = 0;
    ok &= refuse("Y in the input area", 4, 4, (uint32_t)(uintptr_t)W, 0x8000DC00, 8);
    ok &= refuse("Y in the trace buffer", 4, 4, (uint32_t)(uintptr_t)W, 0x8000E000, 8);
    ok &= refuse("Y not aligned", 4, 4, (uint32_t)(uintptr_t)W, (uint32_t)(uintptr_t)Y + 1, 8);
    ok &= check("after the refusals", W, 64, 64, BIAS, 77, 14, 1);

    /* RAW mode */
    ok &= check_raw("raw 64x64", W, 64, 64, BIAS);
    ok &= check_raw("raw 7x12 no bias", W, 12, 7, 0);
    ok &= check_raw("raw 1x4", W, 4, 1, BIAS);
    ok &= check_raw("raw 63x64", W, 64, 63, BIAS);
    ok &= check_raw("raw 3x1024", WB, 1024, 3, BIAS);
    for (int i = 0; i < 1024; i++) {
        X[i] = -128;
    }
    for (int i = 0; i < 3 * 1024; i++) {
        WB[i] = -128;
    }
    ok &= check_raw("raw 3x1024 extreme (all -128)", WB, 1024, 3, BIAS);
    ok &= refuse_ctrl("raw Y runs into the trace buffer", 4, 4, (uint32_t)(uintptr_t)W, 0x8000DFFC, 8, CTRL_START | CTRL_RAW);
    ok &= refuse_ctrl("raw Y not aligned", 4, 4, (uint32_t)(uintptr_t)W, (uint32_t)(uintptr_t)YW + 1, 8, CTRL_START | CTRL_RAW);
    ok &= refuse_ctrl("raw W in the boot ROM", 4, 4, 0x1000, (uint32_t)(uintptr_t)YW, 8, CTRL_START | CTRL_RAW);
    ok &= refuse_ctrl("Q31 with RAW", 4, 4, (uint32_t)(uintptr_t)W, (uint32_t)(uintptr_t)Y, 8, CTRL_START | CTRL_RAW | CTRL_Q31);
    ok &= refuse_ctrl("Q31 shift 31", 4, 4, (uint32_t)(uintptr_t)W, (uint32_t)(uintptr_t)Y, 31, CTRL_START | CTRL_Q31);
    ok &= refuse_ctrl("Q31 shift -32", 4, 4, (uint32_t)(uintptr_t)W, (uint32_t)(uintptr_t)Y, (uint32_t)-32, CTRL_START | CTRL_Q31);
    ok &= refuse_ctrl("Q31 Y in the trace buffer", 4, 4, (uint32_t)(uintptr_t)W, 0x8000E000, (uint32_t)-6, CTRL_START | CTRL_Q31);
    ok &= refuse_ctrl("W4 IN 12 (not a multiple of 8)", 12, 4, (uint32_t)(uintptr_t)W, (uint32_t)(uintptr_t)Y, 8, CTRL_START | CTRL_W4);
    ok &= refuse_ctrl("W4 weights run into the input area's RAM part", 8, 2, 0x8000BFFC, (uint32_t)(uintptr_t)Y, 8, CTRL_START | CTRL_W4);
    ok &= check("byte mode again after raw", W, 64, 64, BIAS, 77, 14, 1);

    puts_(ok ? "AI GEMV OK\n" : "AI GEMV FAIL\n");
    for (;;) {
    }
}
