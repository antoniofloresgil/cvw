/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * wally_fc_s8 (wally_fc.h: the AI unit's RAW product plus the library's requantization) against muriscv_nn_fully_connected_s8 (the library
 * alone) on random layers: different shapes, batch sizes, input and output offsets, multipliers, shifts, clamps, with and without bias, and
 * an extreme case; every output byte must be equal.  Then the cycles of the 64 x 64 layer both ways.  Needs a chip with the unit
 * (asic_soc_rv32imac_ai).  UART as the bootloader left it. */
#include <stdint.h>
#include "common.h"
#include "wally_fc.h"

#define MAXW 4096
#define MAXB 2
#define MAXOUT 64
#define MAXIN 1024
#define REPS 16

static int8_t  W[MAXW] __attribute__((aligned(4)));
static int8_t  X[MAXB * MAXIN] __attribute__((aligned(4)));
static int32_t BIAS[MAXOUT] __attribute__((aligned(4)));
static int32_t FOLD[MAXOUT] __attribute__((aligned(4)));
static int32_t ACC[MAXOUT] __attribute__((aligned(4)));
static int8_t  YL[MAXB * MAXOUT] __attribute__((aligned(4)));
static int8_t  YU[MAXB * MAXOUT] __attribute__((aligned(4)));
static int8_t  YQ[MAXB * MAXOUT] __attribute__((aligned(4)));
static int q31_cases;
static volatile int32_t sink;

static const struct { int in, out, batch; } SHAPES[] = {
    { 4, 1, 1 }, { 12, 7, 1 }, { 64, 64, 1 }, { 64, 64, 2 }, { 256, 10, 1 }, { 256, 10, 2 }, { 1024, 4, 1 }, { 20, 33, 2 }, { 8, 64, 1 },
};
#define NSHAPES (sizeof(SHAPES) / sizeof(SHAPES[0]))

/* one layer both ways; returns the number of different output bytes (-1 if the wrapper refused) */
static int compare(int in, int out, int batch, const int32_t *bias, int32_t in_off, int32_t out_off, int32_t mult, int32_t shift, int32_t amin,
                   int32_t amax)
{
    muriscv_nn_context ctx = { .buf = 0, .size = 0 }, uctx = { .buf = ACC, .size = sizeof(ACC) };
    muriscv_nn_fc_params fc = { .input_offset = in_off, .filter_offset = 0, .output_offset = out_off, .activation = { .min = amin, .max = amax } };
    muriscv_nn_per_tensor_quant_params q = { .multiplier = mult, .shift = shift };
    muriscv_nn_dims in_d = { .n = batch, .h = 1, .w = 1, .c = in }, f_d = { .n = in, .h = 1, .w = 1, .c = out },
                    b_d = { .n = 1, .h = 1, .w = 1, .c = out }, o_d = { .n = 1, .h = 1, .w = 1, .c = out };

    for (int i = 0; i < MAXB * MAXOUT; i++) {
        YL[i] = 0x55;
        YU[i] = 0x55;
        YQ[i] = 0x55;
    }
    if (muriscv_nn_fully_connected_s8(&ctx, &fc, &q, &in_d, X, &f_d, W, &b_d, bias, &o_d, YL) != MURISCV_NN_SUCCESS) {
        return -1;
    }
    wally_fc_s8_prepare(FOLD, W, bias, in, out, in_off);
    if (wally_fc_s8(&uctx, &fc, &q, &in_d, X, &f_d, W, FOLD, &o_d, YU) != MURISCV_NN_SUCCESS) {
        return -1;
    }
    int diff = 0;

    for (int i = 0; i < MAXB * MAXOUT; i++) {
        diff += YL[i] != YU[i];     /* also catches a write past the end (0x55 elsewhere) */
    }
    /* the unit requantizing itself (CTRL Q31); a batch needs the output depth a multiple of four */
    if (batch == 1 || (out & 3) == 0) {
        if (wally_fc_s8_q31(&fc, &q, &in_d, X, &f_d, W, FOLD, &o_d, YQ) != MURISCV_NN_SUCCESS) {
            return -1;
        }
        q31_cases++;
        for (int i = 0; i < MAXB * MAXOUT; i++) {
            diff += YL[i] != YQ[i];
        }
    }
    return diff;
}

int main(void)
{
    int ok = 1, cases = 0;

    puts_("wally_fc_s8 (AI unit RAW + muRISCV-NN requantization) against muriscv_nn_fully_connected_s8\n");
    for (int c = 0; c < 60; c++) {
        int s = c % (int)NSHAPES, in = SHAPES[s].in, out = SHAPES[s].out, batch = SHAPES[s].batch;
        int extreme = c >= 54;      /* the last six: all weights -128, inputs +-127, offsets at the ends */

        for (int i = 0; i < in * out; i++) {
            W[i] = extreme ? (int8_t)-128 : rnd8();
        }
        for (int i = 0; i < in * batch; i++) {
            X[i] = extreme ? (int8_t)(c & 1 ? 127 : -128) : rnd8();
        }
        int hasbias = (rnd32() & 3u) != 0;

        for (int j = 0; j < out; j++) {
            BIAS[j] = (int32_t)(rnd32() >> (extreme ? 2 : 12)) - (extreme ? (1 << 29) : (1 << 19));
        }
        int32_t in_off = extreme ? (c & 1 ? 127 : -128) : (int32_t)(rnd32() % 256u) - 128;
        int32_t out_off = (int32_t)(rnd32() % 256u) - 128;
        int32_t mult = (int32_t)(rnd32() >> 1) | (1 << 29);         /* 0.25 .. 1 in Q31 */
        int32_t shift = (int32_t)(rnd32() % 19u) - 16;              /* -16 .. +2 */
        int32_t amin = (c % 3) == 0 ? 0 : -128, amax = (c % 5) == 0 ? 100 : 127;

        if (c == 7) {
            mult = -mult;           /* a negative multiplier is legal */
        }
        int d = compare(in, out, batch, hasbias ? BIAS : 0, in_off, out_off, mult, shift, amin, amax);

        cases++;
        if (d != 0) {
            ok = 0;
            puts_("MISMATCH case ");
            putu((uint32_t)c);
            puts_(" (");
            putu((uint32_t)in);
            puts_(" x ");
            putu((uint32_t)out);
            puts_(", batch ");
            putu((uint32_t)batch);
            puts_(d < 0 ? ") refused\n" : "): bytes differ\n");
        }
    }
    /* wide ranges for the requantization: biases over the whole int32 (a small dot product leaves them as they are), multipliers over the whole
     * Q31 range but INT32_MIN (the library's documented range), shifts -31..30, offsets and clamps over int32 */
    for (int c = 0; c < 80; c++) {
        int s = c % 5, in = SHAPES[s].in, out = SHAPES[s].out, batch = SHAPES[s].batch;

        if (c % 2) {
            in = 4;
            out = 4 * (1 + (int)(rnd32() % 16u));
            batch = 1 + (int)(rnd32() % 2u);
        }
        for (int i = 0; i < in * out; i++) {
            W[i] = rnd8();
        }
        for (int i = 0; i < in * batch; i++) {
            X[i] = rnd8();
        }
        for (int j = 0; j < out; j++) {
            BIAS[j] = (int32_t)rnd32() >> (rnd32() % 24u);          /* every magnitude, both signs */
        }
        int32_t mult = (int32_t)rnd32() >> (rnd32() % 3u);
        int32_t shift = (int32_t)(rnd32() % 62u) - 31;
        int32_t a0 = (int32_t)(rnd32() >> (rnd32() % 32u)) * ((rnd32() & 1u) ? 1 : -1), a1 = (int32_t)(rnd32() >> (rnd32() % 32u));
        int32_t amin = a0 < a1 ? a0 : a1, amax = a0 < a1 ? a1 : a0;

        if (mult == INT32_MIN) {
            mult = INT32_MAX;
        }
        if (c % 7 == 0) {
            amin = -128;
            amax = 127;
        }
        int d = compare(in, out, batch, BIAS, (int32_t)(rnd32() % 256u) - 128, (int32_t)rnd32() >> (rnd32() % 32u), mult, shift, amin, amax);

        cases++;
        if (d != 0) {
            ok = 0;
            puts_("MISMATCH wide case ");
            putu((uint32_t)c);
            puts_(d < 0 ? " refused\n" : ": bytes differ\n");
        }
    }
    puts_("cases compared: ");
    putu((uint32_t)cases);
    puts_(ok ? ", all equal" : ", DIFFERENCES");
    puts_(" (with the unit requantizing: ");
    putu((uint32_t)q31_cases);
    puts_(")\n");

    /* the 64 x 64 layer of mnn/main.c: cycles */
    int in = 64, out = 64;

    for (int i = 0; i < in * out; i++) {
        W[i] = rnd8();
    }
    for (int i = 0; i < in; i++) {
        X[i] = rnd8();
    }
    for (int j = 0; j < out; j++) {
        BIAS[j] = rnd8() * 16;
    }
    muriscv_nn_context ctx = { .buf = 0, .size = 0 }, uctx = { .buf = ACC, .size = sizeof(ACC) };
    muriscv_nn_fc_params fc = { .input_offset = 128, .filter_offset = 0, .output_offset = -128, .activation = { .min = -128, .max = 127 } };
    muriscv_nn_per_tensor_quant_params q = { .multiplier = 1431655765, .shift = -6 };
    muriscv_nn_dims in_d = { .n = 1, .h = 1, .w = 1, .c = in }, f_d = { .n = in, .h = 1, .w = 1, .c = out },
                    b_d = { .n = 1, .h = 1, .w = 1, .c = out }, o_d = { .n = 1, .h = 1, .w = 1, .c = out };

    uint32_t c0 = mcycle_();

    wally_fc_s8_prepare(FOLD, W, BIAS, in, out, 128);
    uint32_t c1 = mcycle_();

    for (int k = 0; k < REPS; k++) {
        muriscv_nn_fully_connected_s8(&ctx, &fc, &q, &in_d, X, &f_d, W, &b_d, BIAS, &o_d, YL);
    }
    uint32_t c2 = mcycle_();

    for (int k = 0; k < REPS; k++) {
        wally_fc_s8(&uctx, &fc, &q, &in_d, X, &f_d, W, FOLD, &o_d, YU);
    }
    uint32_t c3 = mcycle_();
    uint32_t unit = wally_ai_cycles();

    /* the library's requantization of the 64 accumulators alone, with the multiplier and the shift not known to the compiler */
    static volatile int32_t vmult = 1431655765, vshift = -6;
    int32_t m = vmult, sh = vshift, s = 0;
    uint32_t c4 = mcycle_();

    for (int k = 0; k < REPS; k++) {
        for (int j = 0; j < out; j++) {
            s += muriscv_nn_requantize(ACC[j] + k, m, sh);
        }
    }
    uint32_t c5 = mcycle_();

    sink = s;

    uint32_t c6 = mcycle_();

    for (int k = 0; k < REPS; k++) {
        wally_fc_s8_q31(&fc, &q, &in_d, X, &f_d, W, FOLD, &o_d, YQ);
    }
    uint32_t c7 = mcycle_();
    uint32_t unitq = wally_ai_cycles();
    int same = 1;

    for (int j = 0; j < out; j++) {
        same &= YL[j] == YQ[j];
    }

    for (int j = 0; j < out; j++) {
        same &= YL[j] == YU[j];
    }
    ok &= same;
    puts_("64 x 64 layer: library ");
    putu((c2 - c1) / REPS);
    puts_(" cycles, with the unit ");
    putu((c3 - c2) / REPS);
    puts_(" cycles (the unit's own: ");
    putu(unit);
    puts_("), prepare once ");
    putu(c1 - c0);
    puts_(" cycles\n");
    puts_("requantization of the 64 outputs alone, parameters at run time: ");
    putu((c5 - c4) / REPS);
    puts_(" cycles\n");
    puts_("64 x 64 layer, the unit requantizing (Q31): ");
    putu((c7 - c6) / REPS);
    puts_(" cycles (the unit's own: ");
    putu(unitq);
    puts_(")\n");
    puts_(ok ? "WALLY FC OK\n" : "WALLY FC FAIL\n");
    for (;;) {
    }
}
