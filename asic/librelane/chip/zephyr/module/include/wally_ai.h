/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Driver of the chip's int8 matrix-vector unit (src/uncore/ai/ai_unit.sv, docs/engineering/decisions/0024-edge-ai-accelerator.md) for a layer of
 * a neural network, in one call, in one of three modes:
 *   WALLY_AI_BYTE  y = clamp(((W x + bias) * mult) >> shift), int8 (the unit's own requantization, a 16-bit multiplier)
 *   WALLY_AI_RAW   acc = W x + bias, an int32 per output: for a library that requantizes in software
 *   WALLY_AI_Q31   y = clamp(requantize(W x + bias, q31_mult, q31_shift) + offset, act_min, act_max), int8: the requantization of CMSIS-NN and
 *                  muRISCV-NN (Q31 doubling-high multiply with rounding, rounding divide by a power of two, output offset, clamp), bit for bit
 * The unit reads W, x and the bias from the RAM with its own bus master and writes the result there.  All buffers must lie in the RAM outside
 * the trace buffer, aligned to four bytes. */
#ifndef WALLY_AI_H
#define WALLY_AI_H

#include <stdbool.h>
#include <stdint.h>
#include <zephyr/device.h>

enum wally_ai_mode {
    WALLY_AI_BYTE = 0,       /* the default: a job that does not set mode is a byte-mode job */
    WALLY_AI_RAW,
    WALLY_AI_Q31,
};

struct wally_ai_job {
    const int8_t *w;         /* out rows of in int8, row-major */
    const int8_t *x;         /* in int8 */
    const int32_t *bias;     /* out int32, or NULL for none */
    int8_t *y;               /* out int8 (BYTE and Q31) */
    uint16_t in;             /* a multiple of 4, 4..1024 */
    uint16_t out;            /* 1..65535 */
    int16_t mult;            /* BYTE: signed 16-bit multiplier */
    uint8_t shift;           /* BYTE: arithmetic right shift, 0..47 */
    bool relu;               /* BYTE: clamp to 0..127 instead of -128..127 */
    enum wally_ai_mode mode;
    int32_t *acc;            /* RAW: out int32 words are written here (y is not used) */
    int32_t q31_mult;        /* Q31: multiplier in Q31, as the library's quant_params.multiplier */
    int32_t q31_shift;       /* Q31: -31..30, as the library's quant_params.shift (positive: the accumulator is shifted left first) */
    int32_t offset;          /* Q31: output offset, added to the requantized value */
    int32_t act_min;         /* Q31: clamp, the low byte of the result is stored (-128..127 for int8) */
    int32_t act_max;
};

/* Run the job and wait for it (the unit takes about in/4 + 5 clocks per output, a few more in RAW mode).  Returns 0, -EINVAL if the unit
 * refused the arguments (also a Q31 shift outside -31..30), -EIO on a bus error.  *cycles, if not NULL, gets the clocks of the run from the unit's own counter.  Calls from several
 * threads are serialized. */
int wally_ai_run(const struct device *dev, const struct wally_ai_job *job, uint32_t *cycles);

#endif
