/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * A trained network on the chip: the 64-64-32-10 MLP of model/train_digits.py (int8 weights, or int4 weights with -DDIGITS_W4) (8 x 8 digits), its test samples in digits_model.h.
 * Every sample runs on the unit in Q31 mode (the unit requantizes), its class is compared with the label (accuracy) and with the class of the
 * host's bit-exact integer model (it must be the same on every sample).  The first samples also run the library on the core and the unit in RAW
 * mode, and every layer's bytes must be equal in the three.  Cycles of an inference on the unit and in the library are printed.  Needs a chip
 * with the unit (asic_soc_rv32imac_ai).  UART as the bootloader left it. */
#include <stdint.h>
#include "common.h"
#include "wally_fc.h"
#ifdef DIGITS_W4        /* int4 weights (model/train_digits.py --bits 4): the library's s4 function, CTRL W4 on the unit */
#include "model/digits4_model.h"
#define WBITS "4"
#define FC_LIB muriscv_nn_fully_connected_s4
#define FC_RAW wally_fc_s4
#define FC_Q31 wally_fc_s4_q31
#define FC_PREPARE wally_fc_s4_prepare
#else
#include "model/digits_model.h"
#define WBITS "8"
#define FC_LIB muriscv_nn_fully_connected_s8
#define FC_RAW wally_fc_s8
#define FC_Q31 wally_fc_s8_q31
#define FC_PREPARE wally_fc_s8_prepare
#endif

#define CHECKED 8       /* samples that also run the library and the RAW mode (the library takes 170,000 cycles each) */

static const int8_t *const DW[3] = { DW1, DW2, DW3 };
static const int32_t *const DB[3] = { DB1, DB2, DB3 };
static int32_t F1[64] __attribute__((aligned(4)));
static int32_t F2[32] __attribute__((aligned(4)));
static int32_t F3[10] __attribute__((aligned(4)));
static int32_t *const F[3] = { F1, F2, F3 };
static int32_t ACC[64] __attribute__((aligned(4)));
static int8_t  H1[3][64] __attribute__((aligned(4)));
static int8_t  H2[3][32] __attribute__((aligned(4)));
static int8_t  Y[3][12] __attribute__((aligned(4)));
static int8_t  XS[64] __attribute__((aligned(4)));      /* the sample in RAM aligned for the unit (the arrays of the header are too, but a row is not) */

enum { LIB, RAW, Q31 };

static int layer(int path, int l, const int8_t *x, int8_t *y)
{
    const struct digits_layer *p = &DL[l];
    muriscv_nn_context ctx = { .buf = 0, .size = 0 }, uctx = { .buf = ACC, .size = sizeof(ACC) };
    muriscv_nn_fc_params fc = { .input_offset = p->in_off, .filter_offset = 0, .output_offset = p->out_off,
                                .activation = { .min = p->amin, .max = p->amax } };
    muriscv_nn_per_tensor_quant_params q = { .multiplier = p->mult, .shift = p->shift };
    muriscv_nn_dims in_d = { .n = 1, .h = 1, .w = 1, .c = p->in }, f_d = { .n = p->in, .h = 1, .w = 1, .c = p->out },
                    b_d = { .n = 1, .h = 1, .w = 1, .c = p->out }, o_d = { .n = 1, .h = 1, .w = 1, .c = p->out };
    muriscv_nn_status st;

    if (path == LIB) {
        st = FC_LIB(&ctx, &fc, &q, &in_d, x, &f_d, DW[l], &b_d, DB[l], &o_d, y);
    } else if (path == RAW) {
        st = FC_RAW(&uctx, &fc, &q, &in_d, x, &f_d, DW[l], F[l], &o_d, y);
    } else {
        st = FC_Q31(&fc, &q, &in_d, x, &f_d, DW[l], F[l], &o_d, y);
    }
    return st == MURISCV_NN_SUCCESS ? 0 : -1;
}

static int forward(int path, const int8_t *x)
{
    return layer(path, 0, x, H1[path]) || layer(path, 1, H1[path], H2[path]) || layer(path, 2, H2[path], Y[path]);
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

int main(void)
{
    int ok = 1, correct = 0, correct_lib = 0, differs = 0, refused = 0, unequal = 0;
    uint32_t cyc_unit = 0, cyc_lib = 0;

    puts_("digits: 64-64-32-10 MLP with int" WBITS " weights, ");
    putu(DIGITS_N);
    puts_(" test samples\n");
    for (int l = 0; l < 3; l++) {
        FC_PREPARE(F[l], DW[l], DB[l], DL[l].in, DL[l].out, DL[l].in_off);
    }
    for (int n = 0; n < DIGITS_N; n++) {
        for (int i = 0; i < 64; i++) {
            XS[i] = DX[n * 64 + i];
        }
        uint32_t c0 = mcycle_();

        refused += forward(Q31, XS) != 0;
        cyc_unit += mcycle_() - c0;
        int cls = argmax(Y[Q31], 10);

        correct += cls == DLABEL[n];
        differs += cls != DREF[n];
        if (n < CHECKED) {
            uint32_t c1 = mcycle_();

            refused += forward(LIB, XS) != 0;
            cyc_lib += mcycle_() - c1;
            refused += forward(RAW, XS) != 0;
            correct_lib += argmax(Y[LIB], 10) == DLABEL[n];
            unequal += !(same(H1[LIB], H1[RAW], 64) && same(H1[LIB], H1[Q31], 64) && same(H2[LIB], H2[RAW], 32) && same(H2[LIB], H2[Q31], 32) &&
                         same(Y[LIB], Y[RAW], 10) && same(Y[LIB], Y[Q31], 10));
        }
    }
    puts_("first ");
    putu(CHECKED);
    puts_(": library, unit RAW and unit Q31 equal in every layer on ");
    putu(CHECKED - (unsigned)unequal);
    puts_(" of ");
    putu(CHECKED);
    puts_(", library correct ");
    putu((uint32_t)correct_lib);
    puts_("\n");
    puts_("unit Q31: correct ");
    putu((uint32_t)correct);
    puts_(" of ");
    putu(DIGITS_N);
    puts_(", class different from the host's integer model on ");
    putu((uint32_t)differs);
    puts_("\n");
    puts_("cycles per inference: unit Q31 ");
    putu(cyc_unit / DIGITS_N);
    puts_(", library ");
    putu(cyc_lib / CHECKED);
    puts_("\n");
    ok = refused == 0 && unequal == 0 && differs == 0 && correct == DIGITS_EXPECTED_CORRECT;
    puts_(ok ? "DIGITS OK\n" : "DIGITS FAIL\n");
    for (;;) {
    }
}
