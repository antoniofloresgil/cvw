/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * A small int8 network, 64 -> 64 -> 32 -> 10 (two ReLU layers and a last layer without activation), run three ways with the same random
 * weights and inputs: the library's muriscv_nn_fully_connected_s8 on the core, wally_fc_s8 (the AI unit's RAW product, the library's
 * requantization in software) and wally_fc_s8_q31 (the unit requantizes too).  Every layer's output bytes must be equal in the three; the cycles
 * of each layer and of the whole network are printed (step 3 of docs/engineering/decisions/0024-edge-ai-accelerator.md).  Needs a chip with the
 * unit (asic_soc_rv32imac_ai).  UART as the bootloader left it. */
#include <stdint.h>
#include "common.h"
#include "wally_fc.h"

#define NLAYERS 3
#define NINPUTS 8

struct layer {
    int in, out;
    int32_t in_off, out_off, mult, shift, amin, amax;
};

/* quantization chosen so that the outputs use the int8 range: input zero point 128 for the raw input (unsigned-like), ReLU as a clamp at the
 * output zero point (-128), no clamp on the logits */
static const struct layer L[NLAYERS] = {
    { 64, 64, 128, -128, 1073741824, -9, -128, 127 },
    { 64, 32, 128, -128, 1073741824, -9, -128, 127 },
    { 32, 10, 128, 0, 1073741824, -7, -128, 127 },
};

static int8_t  W1[64 * 64] __attribute__((aligned(4)));
static int8_t  W2[64 * 32] __attribute__((aligned(4)));
static int8_t  W3[32 * 10] __attribute__((aligned(4)));
static int32_t B1[64] __attribute__((aligned(4)));
static int32_t B2[32] __attribute__((aligned(4)));
static int32_t B3[10] __attribute__((aligned(4)));
static int32_t F1[64] __attribute__((aligned(4)));
static int32_t F2[32] __attribute__((aligned(4)));
static int32_t F3[10] __attribute__((aligned(4)));
static int32_t ACC[64] __attribute__((aligned(4)));
static int8_t  X[64] __attribute__((aligned(4)));
/* the activations of each path: layer 1 output, layer 2 output, logits */
static int8_t  H1[3][64] __attribute__((aligned(4)));
static int8_t  H2[3][32] __attribute__((aligned(4)));
static int8_t  Y[3][12] __attribute__((aligned(4)));

static const int8_t *const W[NLAYERS] = { W1, W2, W3 };
static const int32_t *const B[NLAYERS] = { B1, B2, B3 };
static int32_t *const F[NLAYERS] = { F1, F2, F3 };

enum { LIB, RAW, Q31 };
static uint32_t cyc[3][NLAYERS];        /* cycles added up over the inputs */
static uint32_t prep;                   /* cycles of the one-time preparation of the three layers (folded biases) */

/* one layer, one path: returns 0 or -1 if the path refused it */
static int layer(int path, int l, const int8_t *x, int8_t *y)
{
    const struct layer *p = &L[l];
    muriscv_nn_context ctx = { .buf = 0, .size = 0 }, uctx = { .buf = ACC, .size = sizeof(ACC) };
    muriscv_nn_fc_params fc = { .input_offset = p->in_off, .filter_offset = 0, .output_offset = p->out_off,
                                .activation = { .min = p->amin, .max = p->amax } };
    muriscv_nn_per_tensor_quant_params q = { .multiplier = p->mult, .shift = p->shift };
    muriscv_nn_dims in_d = { .n = 1, .h = 1, .w = 1, .c = p->in }, f_d = { .n = p->in, .h = 1, .w = 1, .c = p->out },
                    b_d = { .n = 1, .h = 1, .w = 1, .c = p->out }, o_d = { .n = 1, .h = 1, .w = 1, .c = p->out };
    muriscv_nn_status st;
    uint32_t c0 = mcycle_();

    if (path == LIB) {
        st = muriscv_nn_fully_connected_s8(&ctx, &fc, &q, &in_d, x, &f_d, W[l], &b_d, B[l], &o_d, y);
    } else if (path == RAW) {
        st = wally_fc_s8(&uctx, &fc, &q, &in_d, x, &f_d, W[l], F[l], &o_d, y);
    } else {
        st = wally_fc_s8_q31(&fc, &q, &in_d, x, &f_d, W[l], F[l], &o_d, y);
    }
    cyc[path][l] += mcycle_() - c0;
    return st == MURISCV_NN_SUCCESS ? 0 : -1;
}

static int forward(int path, const int8_t *x)
{
    if (layer(path, 0, x, H1[path]) || layer(path, 1, H1[path], H2[path]) || layer(path, 2, H2[path], Y[path])) {
        return -1;
    }
    return 0;
}

static int argmax(const int8_t *v, int n)
{
    int best = 0;

    for (int i = 1; i < n; i++) {
        best = v[i] > v[best] ? i : best;
    }
    return best;
}

static int same(const int8_t *a, const int8_t *b, int n)
{
    for (int i = 0; i < n; i++) {
        if (a[i] != b[i]) {
            return 0;
        }
    }
    return 1;
}

static void put3(const char *name, int l)
{
    puts_(name);
    putu(cyc[LIB][l] / NINPUTS);
    puts_(", unit RAW ");
    putu(cyc[RAW][l] / NINPUTS);
    puts_(", unit Q31 ");
    putu(cyc[Q31][l] / NINPUTS);
    puts_("\n");
}

int main(void)
{
    int ok = 1;

    puts_("network 64-64-32-10: library, unit RAW and unit Q31 on the same weights\n");
    for (int i = 0; i < 64 * 64; i++) {
        W1[i] = rnd8();
    }
    for (int i = 0; i < 64 * 32; i++) {
        W2[i] = rnd8();
    }
    for (int i = 0; i < 32 * 10; i++) {
        W3[i] = rnd8();
    }
    for (int i = 0; i < 64; i++) {
        B1[i] = rnd8() * 16;
    }
    for (int i = 0; i < 32; i++) {
        B2[i] = rnd8() * 16;
    }
    for (int i = 0; i < 10; i++) {
        B3[i] = rnd8() * 16;
    }
    uint32_t c0 = mcycle_();

    for (int l = 0; l < NLAYERS; l++) {
        wally_fc_s8_prepare(F[l], W[l], B[l], L[l].in, L[l].out, L[l].in_off);
    }
    prep = mcycle_() - c0;

    for (int n = 0; n < NINPUTS; n++) {
        for (int i = 0; i < 64; i++) {
            X[i] = rnd8();
        }
        for (int p = 0; p < 3; p++) {
            if (forward(p, X) != 0) {
                ok = 0;
                puts_("REFUSED path ");
                putu((uint32_t)p);
                puts_("\n");
            }
        }
        int eq = same(H1[LIB], H1[RAW], 64) && same(H1[LIB], H1[Q31], 64) && same(H2[LIB], H2[RAW], 32) && same(H2[LIB], H2[Q31], 32) &&
                 same(Y[LIB], Y[RAW], 10) && same(Y[LIB], Y[Q31], 10);

        ok &= eq;
        puts_("input ");
        putu((uint32_t)n);
        puts_(eq ? ": equal, class " : ": DIFFERENT, class ");
        putu((uint32_t)argmax(Y[LIB], 10));
        puts_(" (");
        putu((uint32_t)argmax(Y[RAW], 10));
        puts_(", ");
        putu((uint32_t)argmax(Y[Q31], 10));
        puts_(")\n");
    }
    puts_("cycles per layer (mean over the inputs)\n");
    put3("layer 1 (64 x 64): library ", 0);
    put3("layer 2 (64 x 32): library ", 1);
    put3("layer 3 (32 x 10): library ", 2);
    puts_("whole network: library ");
    putu((cyc[LIB][0] + cyc[LIB][1] + cyc[LIB][2]) / NINPUTS);
    puts_(", unit RAW ");
    putu((cyc[RAW][0] + cyc[RAW][1] + cyc[RAW][2]) / NINPUTS);
    puts_(", unit Q31 ");
    putu((cyc[Q31][0] + cyc[Q31][1] + cyc[Q31][2]) / NINPUTS);
    puts_(" cycles; preparation once ");
    putu(prep);
    puts_(" cycles\n");
    puts_(ok ? "MLP OK\n" : "MLP FAIL\n");
    for (;;) {
    }
}
