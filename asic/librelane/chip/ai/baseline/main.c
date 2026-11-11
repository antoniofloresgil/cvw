/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Software reference for the AI unit: how many clock cycles an int8 multiply-accumulate (MAC) takes on the chip's RV32IMAC core, as plain C
 * a firmware would have today.  Four dot-product kernels over the same data (they must give the same result), then a fully connected layer
 * (64 inputs, 64 outputs, bias, fixed-point requantization, clamp, ReLU) built on the naive and on the best kernel.  The counters are mcycle
 * and minstret (so the instructions per cycle show too).  The UART is the one the bootloader left (115200 baud with all of SW[4:0] down).
 *
 * The cost of a MAC here is the number to beat: the AI unit is worth building if it brings it well below this. */
#include <stdint.h>

#define UART_BASE 0x10000000UL
#define UART_THR  (*(volatile uint8_t *)(UART_BASE + 0))
#define UART_LSR  (*(volatile uint8_t *)(UART_BASE + 5)) /* bit 5: transmit holding empty */

#define N      256   /* length of a dot product */
#define REPS   16    /* calls per measurement */
#define IN     64    /* the layer: inputs */
#define OUT    64    /* and outputs */

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

static void put_fixed2(uint32_t x100) /* x100 / 100 with two decimals */
{
    putu(x100 / 100);
    putc_('.');
    putc_((char)('0' + (x100 / 10) % 10));
    putc_((char)('0' + x100 % 10));
}

static inline uint32_t rdcycle(void)
{
    uint32_t c;

    __asm__ volatile("csrr %0, mcycle" : "=r"(c));
    return c;
}

static inline uint32_t rdinstret(void)
{
    uint32_t c;

    __asm__ volatile("csrr %0, minstret" : "=r"(c));
    return c;
}

static int8_t  A[N] __attribute__((aligned(4)));
static int8_t  B[N] __attribute__((aligned(4)));
static int8_t  W[OUT][IN] __attribute__((aligned(4)));
static int8_t  X[IN] __attribute__((aligned(4)));
static int32_t BIAS[OUT];
static int8_t  Y0[OUT], Y1[OUT];

static uint32_t seed = 12345;

static int8_t rnd8(void)
{
    seed ^= seed << 13;
    seed ^= seed >> 17;
    seed ^= seed << 5;
    return (int8_t)(seed >> 8);
}

/* 1. as a C programmer writes it */
static int32_t dot_naive(const int8_t *a, const int8_t *b, int n)
{
    int32_t s = 0;

    for (int i = 0; i < n; i++) {
        s += a[i] * b[i];
    }
    return s;
}

/* 2. unrolled by four: less loop overhead */
static int32_t dot_unroll4(const int8_t *a, const int8_t *b, int n)
{
    int32_t s = 0;

    for (int i = 0; i < n; i += 4) {
        s += a[i] * b[i];
        s += a[i + 1] * b[i + 1];
        s += a[i + 2] * b[i + 2];
        s += a[i + 3] * b[i + 3];
    }
    return s;
}

/* 3. a 32-bit load of four bytes from each vector, the bytes taken out with shifts */
static int32_t dot_word(const int8_t *a, const int8_t *b, int n)
{
    const uint32_t *pa = (const uint32_t *)a, *pb = (const uint32_t *)b;
    int32_t s = 0;

    for (int i = 0; i < n / 4; i++) {
        uint32_t x = pa[i], y = pb[i];

        s += (int8_t)x * (int8_t)y;
        s += (int8_t)(x >> 8) * (int8_t)(y >> 8);
        s += (int8_t)(x >> 16) * (int8_t)(y >> 16);
        s += ((int32_t)x >> 24) * ((int32_t)y >> 24);
    }
    return s;
}

/* 4. the word kernel unrolled by two (eight MACs per turn) */
static int32_t dot_word2(const int8_t *a, const int8_t *b, int n)
{
    const uint32_t *pa = (const uint32_t *)a, *pb = (const uint32_t *)b;
    int32_t s = 0;

    for (int i = 0; i < n / 4; i += 2) {
        uint32_t x = pa[i], y = pb[i], u = pa[i + 1], v = pb[i + 1];

        s += (int8_t)x * (int8_t)y;
        s += (int8_t)(x >> 8) * (int8_t)(y >> 8);
        s += (int8_t)(x >> 16) * (int8_t)(y >> 16);
        s += ((int32_t)x >> 24) * ((int32_t)y >> 24);
        s += (int8_t)u * (int8_t)v;
        s += (int8_t)(u >> 8) * (int8_t)(v >> 8);
        s += (int8_t)(u >> 16) * (int8_t)(v >> 16);
        s += ((int32_t)u >> 24) * ((int32_t)v >> 24);
    }
    return s;
}

typedef int32_t (*dot_fn)(const int8_t *, const int8_t *, int);

/* requantization of an accumulator to int8: (acc + bias) * M >> S, clamped, ReLU */
static int8_t requant(int32_t acc, int32_t bias)
{
    int32_t v = (int32_t)(((int64_t)(acc + bias) * 77) >> 14);

    if (v > 127) {
        v = 127;
    }
    if (v < 0) {
        v = 0;
    }
    return (int8_t)v;
}

static void layer(dot_fn dot, int8_t *y)
{
    for (int j = 0; j < OUT; j++) {
        y[j] = requant(dot(W[j], X, IN), BIAS[j]);
    }
}

static volatile int32_t sink;

/* run the kernel (or the layer) REPS times: print cycles per call, per MAC (x100), instructions per MAC and the IPC */
static void measure(const char *name, dot_fn dot, int macs_per_call, int use_layer, int8_t *y)
{
    uint32_t c0, i0, c1, i1;
    int32_t r = 0;

    c0 = rdcycle();
    i0 = rdinstret();
    for (int k = 0; k < REPS; k++) {
        if (use_layer) {
            layer(dot, y);
            r += y[k % OUT];
        } else {
            r += dot(A, B, N);
        }
    }
    c1 = rdcycle();
    i1 = rdinstret();
    sink = r;
    uint32_t cyc = c1 - c0, ins = i1 - i0;
    uint32_t macs = (uint32_t)macs_per_call * REPS;

    puts_(name);
    puts_(": ");
    putu(cyc / REPS);
    puts_(" cycles/call, ");
    put_fixed2(cyc * 100 / macs);
    puts_(" cycles/MAC, ");
    put_fixed2(ins * 100 / macs);
    puts_(" instr/MAC, IPC ");
    put_fixed2(ins * 100 / cyc);
    putc_('\n');
}

int main(void)
{
    puts_("AI baseline (int8 MAC on RV32IMAC)\n");
    for (int i = 0; i < N; i++) {
        A[i] = rnd8();
        B[i] = rnd8();
    }
    for (int j = 0; j < OUT; j++) {
        for (int i = 0; i < IN; i++) {
            W[j][i] = rnd8();
        }
        BIAS[j] = rnd8() * 16;
    }
    for (int i = 0; i < IN; i++) {
        X[i] = rnd8();
    }

    /* the four kernels must agree */
    int32_t ref = dot_naive(A, B, N);
    int ok = dot_unroll4(A, B, N) == ref && dot_word(A, B, N) == ref && dot_word2(A, B, N) == ref;

    layer(dot_naive, Y0);
    layer(dot_word2, Y1);
    for (int j = 0; j < OUT; j++) {
        ok &= Y0[j] == Y1[j];
    }
    puts_("kernels agree: ");
    puts_(ok ? "yes\n" : "NO\n");

    puts_("dot product of ");
    putu(N);
    puts_(" int8, ");
    putu(REPS);
    puts_(" calls\n");
    measure("naive   ", dot_naive, N, 0, 0);
    measure("unroll4 ", dot_unroll4, N, 0, 0);
    measure("word    ", dot_word, N, 0, 0);
    measure("word x2 ", dot_word2, N, 0, 0);
    puts_("layer ");
    putu(IN);
    puts_(" x ");
    putu(OUT);
    puts_(" with bias, requantization, clamp, ReLU\n");
    measure("layer naive", dot_naive, IN * OUT, 1, Y0);
    measure("layer word2", dot_word2, IN * OUT, 1, Y1);

    puts_(ok ? "AI BASELINE OK\n" : "AI BASELINE FAIL\n");
    for (;;) {
    }
}
