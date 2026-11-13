/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Int4 weights on the AI unit (CTRL W4, wally_fc.h: wally_fc_s4 and wally_fc_s4_q31) against muriscv_nn_fully_connected_s4 (the library alone) on
 * random layers: shapes, batch sizes, input and output offsets, multipliers, shifts, clamps, with and without bias, and extreme weights and inputs;
 * every output byte must be equal in the library, the unit's RAW mode and its Q31 mode.  Then the unit's cycles of the 64 x 64 layer with int8 and
 * int4 weights, and the weight bytes of each.  Needs a chip with the unit (asic_soc_rv32imac_ai).  UART as the bootloader left it. */
#include <stdint.h>
#include "common.h"
#include "wally_fc.h"

#define MAXOUT 64
#define MAXIN 1024
#define MAXW4 4096              /* packed bytes: up to 8192 weights */
#define MAXB 2
#define REPS 16

static int8_t  W4[MAXW4] __attribute__((aligned(4)));
static int8_t  W8[4096] __attribute__((aligned(4)));
static int8_t  X[MAXB * MAXIN] __attribute__((aligned(4)));
static int32_t BIAS[MAXOUT] __attribute__((aligned(4)));
static int32_t FOLD[MAXOUT] __attribute__((aligned(4)));
static int32_t FOLD8[MAXOUT] __attribute__((aligned(4)));
static int32_t ACC[MAXOUT] __attribute__((aligned(4)));
static int8_t  YL[MAXB * MAXOUT] __attribute__((aligned(4)));
static int8_t  YU[MAXB * MAXOUT] __attribute__((aligned(4)));
static int8_t  YQ[MAXB * MAXOUT] __attribute__((aligned(4)));
static int q31_cases;

static const struct { int in, out, batch; } SHAPES[] = {
    { 8, 1, 1 }, { 16, 7, 1 }, { 64, 64, 1 }, { 64, 64, 2 }, { 256, 10, 1 }, { 256, 10, 2 }, { 1024, 4, 1 }, { 24, 33, 2 }, { 8, 64, 1 }, { 64, 10, 1 },
};
#define NSHAPES (sizeof(SHAPES) / sizeof(SHAPES[0]))

/* one layer; returns the number of different output bytes (-1 if the wrapper refused) */
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
    if (muriscv_nn_fully_connected_s4(&ctx, &fc, &q, &in_d, X, &f_d, W4, &b_d, bias, &o_d, YL) != MURISCV_NN_SUCCESS) {
        return -1;
    }
    wally_fc_s4_prepare(FOLD, W4, bias, in, out, in_off);
    if (wally_fc_s4(&uctx, &fc, &q, &in_d, X, &f_d, W4, FOLD, &o_d, YU) != MURISCV_NN_SUCCESS) {
        return -1;
    }
    int diff = 0;

    for (int i = 0; i < MAXB * MAXOUT; i++) {
        diff += YL[i] != YU[i];     /* also catches a write past the end (0x55 elsewhere) */
    }
    if (batch == 1 || (out & 3) == 0) {
        if (wally_fc_s4_q31(&fc, &q, &in_d, X, &f_d, W4, FOLD, &o_d, YQ) != MURISCV_NN_SUCCESS) {
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

    puts_("int4 weights (AI unit W4, RAW and Q31) against muriscv_nn_fully_connected_s4\n");
    for (int c = 0; c < 70; c++) {
        int s = c % (int)NSHAPES, in = SHAPES[s].in, out = SHAPES[s].out, batch = SHAPES[s].batch;
        int extreme = c >= 60;      /* the last ten: all weights -8, inputs +-127, offsets at the ends */

        for (int i = 0; i < in * out / 2; i++) {
            W4[i] = extreme ? (int8_t)0x88 : (int8_t)rnd32();
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
    puts_("cases compared: ");
    putu((uint32_t)cases);
    puts_(ok ? ", all equal" : ", DIFFERENCES");
    puts_(" (with the unit requantizing: ");
    putu((uint32_t)q31_cases);
    puts_(")\n");

    /* the 64 x 64 layer with int8 and with int4 weights (the same values, so the same bytes out): cycles and weight bytes */
    const int in = 64, out = 64;

    for (int i = 0; i < in * out; i += 2) {
        int8_t lo = (int8_t)((int8_t)(rnd32() << 4) >> 4), hi = (int8_t)((int8_t)(rnd32() << 4) >> 4);

        W8[i] = lo;
        W8[i + 1] = hi;
        W4[i / 2] = (int8_t)(((uint8_t)lo & 0xFu) | (((uint8_t)hi & 0xFu) << 4));
    }
    for (int i = 0; i < in; i++) {
        X[i] = rnd8();
    }
    for (int j = 0; j < out; j++) {
        BIAS[j] = rnd8() * 16;
    }
    muriscv_nn_fc_params fc = { .input_offset = 128, .filter_offset = 0, .output_offset = -128, .activation = { .min = -128, .max = 127 } };
    muriscv_nn_per_tensor_quant_params q = { .multiplier = 1431655765, .shift = -6 };
    muriscv_nn_dims in_d = { .n = 1, .h = 1, .w = 1, .c = in }, f_d = { .n = in, .h = 1, .w = 1, .c = out },
                    o_d = { .n = 1, .h = 1, .w = 1, .c = out };

    wally_fc_s8_prepare(FOLD8, W8, BIAS, in, out, 128);
    wally_fc_s4_prepare(FOLD, W4, BIAS, in, out, 128);
    for (int k = 0; k < REPS; k++) {
        wally_fc_s8_q31(&fc, &q, &in_d, X, &f_d, W8, FOLD8, &o_d, YL);
    }
    uint32_t cyc8 = wally_ai_cycles();

    for (int k = 0; k < REPS; k++) {
        wally_fc_s4_q31(&fc, &q, &in_d, X, &f_d, W4, FOLD, &o_d, YQ);
    }
    uint32_t cyc4 = wally_ai_cycles();
    int same = 1;

    for (int j = 0; j < out; j++) {
        same &= YL[j] == YQ[j];
    }
    ok &= same;
    puts_("64 x 64 layer, the unit in Q31: int8 weights ");
    putu(cyc8);
    puts_(" cycles and ");
    putu(in * out);
    puts_(" weight bytes, int4 weights ");
    putu(cyc4);
    puts_(" cycles and ");
    putu(in * out / 2);
    puts_(" weight bytes, ");
    puts_(same ? "same bytes out\n" : "DIFFERENT bytes out\n");
    puts_(ok ? "INT4 OK\n" : "INT4 FAIL\n");
    for (;;) {
    }
}
