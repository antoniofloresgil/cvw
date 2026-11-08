/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Driver for the two-stage watchdog of asic_soc_rv32imac (src/uncore/mcu/wdt_apb.sv): a down counter reloads
 * from LOAD; the first time it reaches zero a flag is set, the second time (the flag still set) the chip is
 * reset.  Feeding writes KICK_KEY to KICK, which reloads the counter and clears the flag.  Once enabled the
 * watchdog stays on until a reset.  Zephyr's timeout is the time to the reset, so each stage is half of it.
 * Only the reset action is supported (no callback). */
#define DT_DRV_COMPAT wally_wdt

#include <errno.h>
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/watchdog.h>
#include <zephyr/sys/sys_io.h>

#define REG_CTRL   0x00
#define REG_LOAD   0x04
#define REG_KICK   0x0C
#define REG_PSC    0x14
#define CTRL_EN    BIT(0)
#define KICK_KEY   0x5A1CE55AU
#define TICK_HZ    1000000U     /* the prescaler makes the counter tick about once per microsecond */

struct wdt_wally_cfg {
    mem_addr_t base;
    uint32_t f_clk;
};

struct wdt_wally_data {
    bool installed;
};

static int wdt_wally_setup(const struct device *dev, uint8_t options)
{
    const struct wdt_wally_cfg *cfg = dev->config;
    struct wdt_wally_data *data = dev->data;

    if (options != 0U) {
        return -ENOTSUP;                       /* no pause in sleep or while halted by a debugger */
    }
    if (!data->installed) {
        return -ENOTSUP;
    }
    sys_write32(CTRL_EN, cfg->base + REG_CTRL);
    sys_write32(KICK_KEY, cfg->base + REG_KICK);
    return 0;
}

static int wdt_wally_disable(const struct device *dev)
{
    return -EPERM;                             /* EN sticks: only a reset clears it */
}

static int wdt_wally_install_timeout(const struct device *dev, const struct wdt_timeout_cfg *tcfg)
{
    const struct wdt_wally_cfg *cfg = dev->config;
    struct wdt_wally_data *data = dev->data;
    uint64_t load;

    if (data->installed) {
        return -ENOMEM;                        /* one timeout */
    }
    if (tcfg->window.min != 0U || tcfg->window.max == 0U) {
        return -EINVAL;                        /* no window mode */
    }
    if (tcfg->callback != NULL || (tcfg->flags & WDT_FLAG_RESET_MASK) != WDT_FLAG_RESET_SOC) {
        return -ENOTSUP;
    }
    load = (uint64_t)tcfg->window.max * (TICK_HZ / 1000U) / 2U;   /* two stages */
    if (load == 0U || load > UINT32_MAX) {
        return -EINVAL;
    }
    sys_write32(cfg->f_clk / TICK_HZ - 1U, cfg->base + REG_PSC);
    sys_write32((uint32_t)load, cfg->base + REG_LOAD);
    data->installed = true;
    return 0;
}

static int wdt_wally_feed(const struct device *dev, int channel_id)
{
    const struct wdt_wally_cfg *cfg = dev->config;

    if (channel_id != 0) {
        return -EINVAL;
    }
    sys_write32(KICK_KEY, cfg->base + REG_KICK);
    return 0;
}

static DEVICE_API(wdt, wdt_wally_api) = {
    .setup = wdt_wally_setup,
    .disable = wdt_wally_disable,
    .install_timeout = wdt_wally_install_timeout,
    .feed = wdt_wally_feed,
};

#define WDT_WALLY_INIT(n)                                                                          \
    static const struct wdt_wally_cfg wdt_wally_cfg_##n = {                                        \
        .base = DT_INST_REG_ADDR(n),                                                               \
        .f_clk = DT_INST_PROP(n, clock_frequency),                                                 \
    };                                                                                             \
    static struct wdt_wally_data wdt_wally_data_##n;                                               \
    DEVICE_DT_INST_DEFINE(n, NULL, NULL, &wdt_wally_data_##n, &wdt_wally_cfg_##n, POST_KERNEL,     \
                          CONFIG_KERNEL_INIT_PRIORITY_DEFAULT, &wdt_wally_api);

DT_INST_FOREACH_STATUS_OKAY(WDT_WALLY_INIT)
