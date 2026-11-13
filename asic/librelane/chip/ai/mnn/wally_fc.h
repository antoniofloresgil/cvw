/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * muriscv_nn_fully_connected_s8 with the product done by the chip's AI unit (src/uncore/ai, RAW mode: the unit returns the int32
 * accumulator W x + bias) and the library's own requantization in software, so the result is bit for bit the library's
 * (docs/engineering/decisions/0024-edge-ai-accelerator.md).  Bare metal, registers at 0x10084000; the library is used as it is.
 *
 * The library adds the input offset to every x: sum w (x + off) + b = sum w x + (b + off * sum w).  The unit has no input offset, so
 * the second term is folded into the bias once, when the layer is prepared (TFLite Micro's Prepare step):
 *     wally_fc_s8_prepare(folded, w, bias, in, out, input_offset);
 * and each call is   wally_fc_s8(&ctx, &fc, &quant, &in_d, x, &f_d, w, folded, &o_d, y)   with the same arguments as the library's
 * muriscv_nn_fully_connected_s8, the folded bias in place of the bias and ctx->buf pointing to a scratch of 4 * output_depth bytes
 * (the accumulators).
 *
 * What the unit takes (wally_fc_s8_unit_ok): filter_offset 0, input depth a multiple of 4 up to 1024, all buffers (weights, input,
 * folded bias, scratch) aligned to four bytes in the RAM, the weights, the folded bias and the input below 0x8000C000 (the RAM part of the unit's input area, whose macro the unit's
 * input port uses) and none of them in the unit's input area, the last 1 KiB before the trace buffer (0x8000DC00-0x8000DFFF: a program's RAM ends at 0x8000DC00).  Otherwise the call returns MURISCV_NN_ARG_ERROR
 * and the caller uses the library's function. */
#ifndef WALLY_FC_H
#define WALLY_FC_H

#include <stdint.h>
#include "muriscv_nn_functions.h"
#include "muriscv_nn_support_functions.h"

#define WALLY_AI_BASE 0x10084000UL
#define WALLY_AI(off) (*(volatile uint32_t *)(WALLY_AI_BASE + (off)))
#define WALLY_AI_CTRL   0x00
#define WALLY_AI_STATUS 0x04
#define WALLY_AI_IN     0x08
#define WALLY_AI_OUT    0x0C
#define WALLY_AI_W      0x10
#define WALLY_AI_X      0x14
#define WALLY_AI_BIAS   0x18
#define WALLY_AI_Y      0x1C
#define WALLY_AI_MULT   0x20
#define WALLY_AI_SHIFT  0x24
#define WALLY_AI_CYCLES 0x28
#define WALLY_AI_OFFSET 0x2C
#define WALLY_AI_AMIN   0x30
#define WALLY_AI_AMAX   0x34

/* the unit's cycles of the last run (its own counter), for measurements */
static inline uint32_t wally_ai_cycles(void)
{
    return WALLY_AI(WALLY_AI_CYCLES);
}

/* folded[j] = (bias ? bias[j] : 0) + input_offset * sum_i w[j * in + i], computed with the same 32-bit wrap-around as the library */
static inline void wally_fc_s8_prepare(int32_t *folded, const int8_t *w, const int32_t *bias, int32_t in, int32_t out,
                                       int32_t input_offset)
{
    for (int32_t j = 0; j < out; j++) {
        int32_t s = 0;

        for (int32_t i = 0; i < in; i++) {
            s += w[j * in + i];
        }
        folded[j] = (int32_t)((uint32_t)(bias ? bias[j] : 0) + (uint32_t)input_offset * (uint32_t)s);
    }
}

static inline int wally_fc_s8_unit_ok(const muriscv_nn_fc_params *fc, const muriscv_nn_dims *filter_dims, const muriscv_nn_dims *output_dims,
                                      const void *w, const void *x, const void *folded_bias, const void *scratch)
{
    uint32_t in = (uint32_t)filter_dims->n, out = (uint32_t)output_dims->c;

    return fc->filter_offset == 0 && in >= 4 && in <= 1024 && (in & 3u) == 0 && out >= 1 && out <= 65535 &&
           (((uintptr_t)w | (uintptr_t)x | (uintptr_t)folded_bias | (uintptr_t)scratch) & 3u) == 0;
}

static inline muriscv_nn_status wally_fc_s8(const muriscv_nn_context *ctx, const muriscv_nn_fc_params *fc,
                                            const muriscv_nn_per_tensor_quant_params *quant, const muriscv_nn_dims *input_dims,
                                            const q7_t *input, const muriscv_nn_dims *filter_dims, const q7_t *kernel,
                                            const int32_t *folded_bias, const muriscv_nn_dims *output_dims, q7_t *output)
{
    int32_t *acc = (int32_t *)ctx->buf;
    const int32_t in = filter_dims->n, out = output_dims->c;

    if (acc == NULL || ctx->size < 4 * out || !wally_fc_s8_unit_ok(fc, filter_dims, output_dims, kernel, input, folded_bias, acc)) {
        return MURISCV_NN_ARG_ERROR;
    }
    for (int32_t batch = input_dims->n; batch > 0; batch--) {
        WALLY_AI(WALLY_AI_IN) = (uint32_t)in;
        WALLY_AI(WALLY_AI_OUT) = (uint32_t)out;
        WALLY_AI(WALLY_AI_W) = (uint32_t)(uintptr_t)kernel;
        WALLY_AI(WALLY_AI_X) = (uint32_t)(uintptr_t)input;
        WALLY_AI(WALLY_AI_BIAS) = (uint32_t)(uintptr_t)folded_bias;
        WALLY_AI(WALLY_AI_Y) = (uint32_t)(uintptr_t)acc;
        WALLY_AI(WALLY_AI_CTRL) = 1u | 4u;          /* START, RAW */
        uint32_t st;

        do {
            st = WALLY_AI(WALLY_AI_STATUS);
        } while (st & 1u);
        WALLY_AI(WALLY_AI_STATUS) = 6u;             /* clear DONE and ERROR */
        if ((st & 4u) != 0u) {
            return MURISCV_NN_ARG_ERROR;            /* refused (a buffer outside the usable RAM) or a bus error */
        }
        for (int32_t j = 0; j < out; j++) {
            int32_t v = muriscv_nn_requantize(acc[j], quant->multiplier, quant->shift) + fc->output_offset;

            v = v < fc->activation.min ? fc->activation.min : v;
            output[j] = (int8_t)(v > fc->activation.max ? fc->activation.max : v);
        }
        input += in;
        output += out;
    }
    return MURISCV_NN_SUCCESS;
}

/* The same layer with the unit requantizing as the library does (CTRL Q31: muriscv_nn_requantize, the output offset and the clamp, in the
 * unit): no scratch and no software requantization, the unit writes the bytes.  The output must be aligned to four bytes, and with a batch
 * larger than one the output depth must be a multiple of four (every batch row starts a word).  Shifts outside -31..30 are refused by the
 * unit.  Returns MURISCV_NN_ARG_ERROR where the unit cannot take the layer. */
static inline muriscv_nn_status wally_fc_s8_q31(const muriscv_nn_fc_params *fc, const muriscv_nn_per_tensor_quant_params *quant,
                                                const muriscv_nn_dims *input_dims, const q7_t *input, const muriscv_nn_dims *filter_dims,
                                                const q7_t *kernel, const int32_t *folded_bias, const muriscv_nn_dims *output_dims,
                                                q7_t *output)
{
    const int32_t in = filter_dims->n, out = output_dims->c;

    if (!wally_fc_s8_unit_ok(fc, filter_dims, output_dims, kernel, input, folded_bias, output) ||
        (input_dims->n > 1 && (out & 3) != 0)) {
        return MURISCV_NN_ARG_ERROR;
    }
    for (int32_t batch = input_dims->n; batch > 0; batch--) {
        WALLY_AI(WALLY_AI_IN) = (uint32_t)in;
        WALLY_AI(WALLY_AI_OUT) = (uint32_t)out;
        WALLY_AI(WALLY_AI_W) = (uint32_t)(uintptr_t)kernel;
        WALLY_AI(WALLY_AI_X) = (uint32_t)(uintptr_t)input;
        WALLY_AI(WALLY_AI_BIAS) = (uint32_t)(uintptr_t)folded_bias;
        WALLY_AI(WALLY_AI_Y) = (uint32_t)(uintptr_t)output;
        WALLY_AI(WALLY_AI_MULT) = (uint32_t)quant->multiplier;
        WALLY_AI(WALLY_AI_SHIFT) = (uint32_t)quant->shift;
        WALLY_AI(WALLY_AI_OFFSET) = (uint32_t)fc->output_offset;
        WALLY_AI(WALLY_AI_AMIN) = (uint32_t)fc->activation.min;
        WALLY_AI(WALLY_AI_AMAX) = (uint32_t)fc->activation.max;
        WALLY_AI(WALLY_AI_CTRL) = 1u | 8u;          /* START, Q31 */
        uint32_t st;

        do {
            st = WALLY_AI(WALLY_AI_STATUS);
        } while (st & 1u);
        WALLY_AI(WALLY_AI_STATUS) = 6u;
        if ((st & 4u) != 0u) {
            return MURISCV_NN_ARG_ERROR;
        }
        input += in;
        output += out;
    }
    return MURISCV_NN_SUCCESS;
}

#endif
