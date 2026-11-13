/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Driver of the int8 matrix-vector unit of asic_soc_rv32imac_ai (src/uncore/ai/ai_unit.sv), polled: a run takes a few thousand
 * clocks at most, and the core is stalled while the unit owns the bus. */
#define DT_DRV_COMPAT wally_ai

#include <errno.h>
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/sys/sys_io.h>
#include <wally_ai.h>

#define REG_CTRL   0x00
#define REG_STATUS 0x04
#define REG_IN     0x08
#define REG_OUT    0x0C
#define REG_W      0x10
#define REG_X      0x14
#define REG_BIAS   0x18
#define REG_Y      0x1C
#define REG_MULT   0x20
#define REG_SHIFT  0x24
#define REG_CYCLES 0x28
#define REG_OFFSET 0x2C
#define REG_AMIN   0x30
#define REG_AMAX   0x34
#define CTRL_START BIT(0)
#define CTRL_RELU  BIT(1)
#define CTRL_RAW   BIT(2)
#define CTRL_Q31   BIT(3)
#define ST_BUSY    BIT(0)
#define ST_DONE    BIT(1)
#define ST_ERR     BIT(2)

struct ai_wally_cfg {
    mem_addr_t base;
};

struct ai_wally_data {
    struct k_mutex lock;
};

int wally_ai_run(const struct device *dev, const struct wally_ai_job *job, uint32_t *cycles)
{
    const struct ai_wally_cfg *cfg = dev->config;
    struct ai_wally_data *data = dev->data;
    mem_addr_t b = cfg->base;
    uint32_t st;

    k_mutex_lock(&data->lock, K_FOREVER);
    sys_write32(job->in, b + REG_IN);
    sys_write32(job->out, b + REG_OUT);
    sys_write32((uint32_t)(uintptr_t)job->w, b + REG_W);
    sys_write32((uint32_t)(uintptr_t)job->x, b + REG_X);
    sys_write32((uint32_t)(uintptr_t)job->bias, b + REG_BIAS);     /* NULL: no bias */
    sys_write32((uint32_t)(uintptr_t)(job->mode == WALLY_AI_RAW ? (void *)job->acc : (void *)job->y), b + REG_Y);
    uint32_t ctrl = CTRL_START;

    switch (job->mode) {
    case WALLY_AI_BYTE:
        sys_write32((uint32_t)(uint16_t)job->mult, b + REG_MULT);
        sys_write32(job->shift, b + REG_SHIFT);
        ctrl |= job->relu ? CTRL_RELU : 0U;
        break;
    case WALLY_AI_RAW:                                    /* MULT, SHIFT and RELU are ignored by the unit */
        ctrl |= CTRL_RAW;
        break;
    case WALLY_AI_Q31:
        sys_write32((uint32_t)job->q31_mult, b + REG_MULT);
        sys_write32((uint32_t)job->q31_shift, b + REG_SHIFT);
        sys_write32((uint32_t)job->offset, b + REG_OFFSET);
        sys_write32((uint32_t)job->act_min, b + REG_AMIN);
        sys_write32((uint32_t)job->act_max, b + REG_AMAX);
        ctrl |= CTRL_Q31;
        break;
    default:
        k_mutex_unlock(&data->lock);
        return -EINVAL;
    }
    sys_write32(ctrl, b + REG_CTRL);
    st = sys_read32(b + REG_STATUS);
    bool refused = !(st & ST_BUSY) && (st & ST_ERR);     /* a run cannot end within one register access: ERROR at once is a refusal */

    while (st & ST_BUSY) {
        st = sys_read32(b + REG_STATUS);
    }
    if (cycles != NULL) {
        *cycles = refused ? 0 : sys_read32(b + REG_CYCLES);
    }
    sys_write32(ST_DONE | ST_ERR, b + REG_STATUS);
    k_mutex_unlock(&data->lock);
    return refused ? -EINVAL : (st & ST_ERR) ? -EIO : 0;
}

static int ai_wally_init(const struct device *dev)
{
    struct ai_wally_data *data = dev->data;

    k_mutex_init(&data->lock);
    return 0;
}

#define AI_WALLY_INIT(n)                                                                           \
    static const struct ai_wally_cfg ai_wally_cfg_##n = {.base = DT_INST_REG_ADDR(n)};             \
    static struct ai_wally_data ai_wally_data_##n;                                                 \
    DEVICE_DT_INST_DEFINE(n, ai_wally_init, NULL, &ai_wally_data_##n, &ai_wally_cfg_##n,           \
                          POST_KERNEL, CONFIG_KERNEL_INIT_PRIORITY_DEFAULT, NULL);

DT_INST_FOREACH_STATUS_OKAY(AI_WALLY_INIT)
