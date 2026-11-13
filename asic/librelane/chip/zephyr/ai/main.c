/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * The AI unit under Zephyr (module/drivers/ai_wally.c) on the chip asic_soc_rv32imac_ai: a 64 x 64 fully connected layer on the unit and in C
 * on the same core, outputs compared byte by byte, then the cycles of each (the core's own mcycle around the call), a layer with a bias and
 * ReLU off, the RAW mode (the int32 accumulators), the Q31 mode (the requantization of CMSIS-NN and muRISCV-NN, checked against an independent
 * implementation with 64-bit integers) in two layers, and the jobs the unit refuses.
 * Build with the overlay that enables the unit:  make APP=ai OVERLAY=ai.overlay */
#include <errno.h>
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/sys/printk.h>
#include <wally_ai.h>

#define IN  64
#define OUT 64

static const struct device *const ai = DEVICE_DT_GET(DT_NODELABEL(ai0));

static int8_t W[OUT * IN] __aligned(4);
static int8_t X[IN] __aligned(4);
static int32_t BIAS[OUT] __aligned(4);
static int8_t Y[OUT] __aligned(4);
static int8_t R[OUT] __aligned(4);
static int32_t ACC[OUT] __aligned(4);

static uint32_t seed = 12345;

static int8_t rnd8(void)
{
    seed ^= seed << 13;
    seed ^= seed >> 17;
    seed ^= seed << 5;
    return (int8_t)(seed >> 8);
}

static inline uint32_t rdcycle(void)
{
    uint32_t c;

    __asm__ volatile("csrr %0, mcycle" : "=r"(c));
    return c;
}

/* the same layer in C: the reference and the cost of doing it without the unit */
static void software(const struct wally_ai_job *j)
{
    for (int r = 0; r < j->out; r++) {
        int32_t acc = 0;

        for (int i = 0; i < j->in; i++) {
            acc += j->w[r * j->in + i] * j->x[i];
        }
        int64_t v = ((int64_t)(acc + (j->bias ? j->bias[r] : 0)) * j->mult) >> j->shift;
        int64_t lo = j->relu ? 0 : -128;

        R[r] = (int8_t)(v > 127 ? 127 : v < lo ? lo : v);
    }
}

/* the accumulators W x + bias, in C */
static void accumulate(const struct wally_ai_job *j, int32_t *out)
{
    for (int r = 0; r < j->out; r++) {
        int32_t acc = j->bias ? j->bias[r] : 0;

        for (int i = 0; i < j->in; i++) {
            acc += j->w[r * j->in + i] * j->x[i];
        }
        out[r] = acc;
    }
}

/* the library's requantization, independently: round(acc * mult / 2^31) (ties away from zero), then a rounding right shift by -shift (ties
 * away from zero); a positive shift is a left shift of acc first; then the output offset and the clamp */
static int8_t requant_ref(int32_t acc, const struct wally_ai_job *j)
{
    int64_t v = j->q31_shift > 0 ? ((int64_t)acc << j->q31_shift) : acc;
    int64_t p = v * j->q31_mult;
    int64_t r = p >= 0 ? (p + (1LL << 30)) >> 31 : -((-p + (1LL << 30)) >> 31);

    if (j->q31_shift < 0) {
        int sh = -j->q31_shift;
        int64_t half = 1LL << (sh - 1);

        r = r >= 0 ? (r + half) >> sh : -((-r + half) >> sh);
    }
    r += j->offset;
    return (int8_t)(r > j->act_max ? j->act_max : r < j->act_min ? j->act_min : r);
}

static int fail(const char *what, int v)
{
    printk("AI FAIL %s %d\n", what, v);
    return 1;
}

int main(void)
{
    if (!device_is_ready(ai)) {
        return fail("device not ready", 0);
    }
    printk("ai start\n");
    for (int i = 0; i < OUT * IN; i++) {
        W[i] = rnd8();
    }
    for (int i = 0; i < IN; i++) {
        X[i] = rnd8();
    }
    for (int i = 0; i < OUT; i++) {
        BIAS[i] = rnd8() * 16;
    }

    struct wally_ai_job job = {.w = W, .x = X, .bias = BIAS, .y = Y, .in = IN, .out = OUT, .mult = 77, .shift = 14, .relu = true};
    uint32_t unit_cycles, c0, core_unit, core_sw;

    c0 = rdcycle();
    int rc = wally_ai_run(ai, &job, &unit_cycles);

    core_unit = rdcycle() - c0;
    if (rc) {
        return fail("run", rc);
    }
    c0 = rdcycle();
    software(&job);
    core_sw = rdcycle() - c0;
    for (int i = 0; i < OUT; i++) {
        if (Y[i] != R[i]) {
            return fail("output differs at", i);
        }
    }
    printk("layer %dx%d ok: unit %u cycles, call %u, software %u\n", OUT, IN, unit_cycles, core_unit, core_sw);

    job.relu = false;
    job.bias = NULL;
    job.mult = -300;
    job.shift = 9;
    rc = wally_ai_run(ai, &job, NULL);
    software(&job);
    if (rc) {
        return fail("run 2", rc);
    }
    for (int i = 0; i < OUT; i++) {
        if (Y[i] != R[i]) {
            return fail("output 2 differs at", i);
        }
    }
    printk("signed layer without bias ok\n");

    /* RAW: the accumulators, whatever the byte-mode fields say */
    struct wally_ai_job raw = {.w = W, .x = X, .bias = BIAS, .acc = ACC, .in = IN, .out = OUT, .mode = WALLY_AI_RAW, .mult = 5, .shift = 99, .relu = true};
    int32_t want[OUT];

    rc = wally_ai_run(ai, &raw, &unit_cycles);
    accumulate(&raw, want);
    if (rc) {
        return fail("raw run", rc);
    }
    for (int i = 0; i < OUT; i++) {
        if (ACC[i] != want[i]) {
            return fail("raw output differs at", i);
        }
    }
    printk("raw layer ok: unit %u cycles\n", unit_cycles);

    /* Q31: what TFLite Micro passes (input offset folded into the bias is the caller's business), then a second layer: left shift, negative
     * multiplier, a narrower clamp */
    struct wally_ai_job q = {.w = W, .x = X, .bias = BIAS, .y = Y, .in = IN, .out = OUT, .mode = WALLY_AI_Q31, .q31_mult = 1431655765,
                             .q31_shift = -6, .offset = -128, .act_min = -128, .act_max = 127};

    c0 = rdcycle();
    rc = wally_ai_run(ai, &q, &unit_cycles);
    core_unit = rdcycle() - c0;
    if (rc) {
        return fail("q31 run", rc);
    }
    for (int i = 0; i < OUT; i++) {
        if (Y[i] != requant_ref(want[i], &q)) {
            return fail("q31 output differs at", i);
        }
    }
    printk("q31 layer ok: unit %u cycles, call %u\n", unit_cycles, core_unit);

    q.q31_mult = -1717986918;     /* -0.8 in Q31 */
    q.q31_shift = 2;
    q.offset = 7;
    q.act_min = -90;
    q.act_max = 100;
    q.bias = NULL;
    rc = wally_ai_run(ai, &q, NULL);
    accumulate(&q, want);
    if (rc) {
        return fail("q31 run 2", rc);
    }
    for (int i = 0; i < OUT; i++) {
        if (Y[i] != requant_ref(want[i], &q)) {
            return fail("q31 output 2 differs at", i);
        }
    }
    printk("q31 second layer ok\n");

    job.in = 6;                          /* not a multiple of 4 */
    rc = wally_ai_run(ai, &job, NULL);
    printk("bad arguments %d\n", rc);
    if (rc != -EINVAL) {
        return fail("refusal", rc);
    }
    q.q31_shift = 31;                    /* outside -31..30 */
    rc = wally_ai_run(ai, &q, NULL);
    printk("q31 bad shift %d\n", rc);
    if (rc != -EINVAL) {
        return fail("q31 refusal", rc);
    }
    printk("AI ZEPHYR OK\n");
    return 0;
}
