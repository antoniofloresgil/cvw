/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Driver of the chip's int8 matrix-vector unit (src/uncore/ai/ai_unit.sv, docs/engineering/decisions/0024-edge-ai-accelerator.md):
 * y = clamp(((W x + bias) * mult) >> shift) for a layer of a neural network, in one call.  The unit reads W, x and the bias from the RAM
 * with its own bus master and writes y there, four bytes to a word.  All buffers must lie in the RAM outside the trace buffer, aligned to
 * four bytes. */
#ifndef WALLY_AI_H
#define WALLY_AI_H

#include <stdbool.h>
#include <stdint.h>
#include <zephyr/device.h>

struct wally_ai_job {
    const int8_t *w;         /* out rows of in int8, row-major */
    const int8_t *x;         /* in int8 */
    const int32_t *bias;     /* out int32, or NULL for none */
    int8_t *y;               /* out int8 */
    uint16_t in;             /* a multiple of 4, 4..1024 */
    uint16_t out;            /* 1..65535 */
    int16_t mult;            /* signed 16-bit multiplier */
    uint8_t shift;           /* arithmetic right shift, 0..47 */
    bool relu;               /* clamp to 0..127 instead of -128..127 */
};

/* Run the job and wait for it (the unit takes about in/4 + 5 clocks per output).  Returns 0, -EINVAL if the unit refused the
 * arguments, -EIO on a bus error.  *cycles, if not NULL, gets the clocks of the run from the unit's own counter.  Calls from several
 * threads are serialized. */
int wally_ai_run(const struct device *dev, const struct wally_ai_job *job, uint32_t *cycles);

#endif
