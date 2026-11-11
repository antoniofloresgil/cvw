/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * The AI unit under Zephyr (module/drivers/ai_wally.c) on the chip asic_soc_rv32imac_ai: a 64 x 64 fully connected layer on the unit and in C
 * on the same core, outputs compared byte by byte, then the cycles of each (the core's own mcycle around the call), a refused job, and
 * a layer with a bias and ReLU off.  Build with the overlay that enables the unit:  make APP=ai OVERLAY=ai.overlay */
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

    job.in = 6;                          /* not a multiple of 4 */
    rc = wally_ai_run(ai, &job, NULL);
    printk("bad arguments %d\n", rc);
    if (rc != -EINVAL) {
        return fail("refusal", rc);
    }
    printk("AI ZEPHYR OK\n");
    return 0;
}
