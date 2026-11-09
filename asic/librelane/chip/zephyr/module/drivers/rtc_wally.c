/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Driver for the real-time counter of asic_soc_rv32imac (src/uncore/mcu/rtc_apb.sv), through the RTC API.  The
 * counter holds seconds since 1970-01-01 00:00:00 UTC (a divider makes the ticks 1 Hz) and starts at 0 on every
 * reset: set the time after a reset.  Its one alarm matches all the fields of a date and time, so alarm_set_time()
 * takes a full mask (second, minute, hour, day of the month, month and year) and an alarm in the past is refused.
 * The alarm interrupt, like any, ends a wfi. */
#define DT_DRV_COMPAT wally_rtc

#include <errno.h>
#include <time.h>
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/irq.h>
#include <zephyr/spinlock.h>
#include <zephyr/drivers/rtc.h>
#include <zephyr/sys/timeutil.h>
#include <zephyr/sys/sys_io.h>

#define REG_CTRL   0x00
#define REG_DIV    0x04
#define REG_TIME   0x08
#define REG_ALARM  0x0C
#define REG_STATUS 0x10
#define CTRL_EN    BIT(0)
#define CTRL_IE    BIT(1)

#define ALARM_FIELDS (RTC_ALARM_TIME_MASK_SECOND | RTC_ALARM_TIME_MASK_MINUTE | RTC_ALARM_TIME_MASK_HOUR | \
                      RTC_ALARM_TIME_MASK_MONTHDAY | RTC_ALARM_TIME_MASK_MONTH | RTC_ALARM_TIME_MASK_YEAR)

struct rtc_wally_cfg {
    mem_addr_t base;
    uint32_t div;
    void (*irq_config)(void);
};

struct rtc_wally_data {
    struct k_spinlock lock;
    rtc_alarm_callback cb;
    void *cb_arg;
    bool armed;
};

static inline uint32_t rd(const struct device *dev, uint32_t reg)
{
    return sys_read32(((const struct rtc_wally_cfg *)dev->config)->base + reg);
}

static inline void wr(const struct device *dev, uint32_t reg, uint32_t v)
{
    sys_write32(v, ((const struct rtc_wally_cfg *)dev->config)->base + reg);
}

static bool valid(const struct rtc_time *t)
{
    return t->tm_sec >= 0 && t->tm_sec <= 59 && t->tm_min >= 0 && t->tm_min <= 59 && t->tm_hour >= 0 &&
           t->tm_hour <= 23 && t->tm_mday >= 1 && t->tm_mday <= 31 && t->tm_mon >= 0 && t->tm_mon <= 11 &&
           t->tm_year >= 70 && t->tm_year <= 206;          /* 1970 to 2106: the counter has 32 bits */
}

/* seconds since 1970 of a broken-down time, or -1 when they do not fit the 32-bit counter */
static int64_t to_seconds(const struct rtc_time *t)
{
    struct rtc_time copy = *t;
    int64_t s = timeutil_timegm64(rtc_time_to_tm(&copy));

    return (s < 0 || s > UINT32_MAX) ? -1 : s;
}

static void from_seconds(uint32_t seconds, struct rtc_time *t)
{
    time_t s = seconds;

    gmtime_r(&s, rtc_time_to_tm(t));
    t->tm_isdst = -1;
    t->tm_nsec = 0;
}

static int rtc_wally_set_time(const struct device *dev, const struct rtc_time *timeptr)
{
    int64_t s;

    if (timeptr == NULL || !valid(timeptr)) {
        return -EINVAL;
    }
    s = to_seconds(timeptr);
    if (s < 0) {
        return -EINVAL;
    }
    wr(dev, REG_TIME, (uint32_t)s);
    return 0;
}

static int rtc_wally_get_time(const struct device *dev, struct rtc_time *timeptr)
{
    if (timeptr == NULL) {
        return -EINVAL;
    }
    from_seconds(rd(dev, REG_TIME), timeptr);
    return 0;
}

#ifdef CONFIG_RTC_ALARM
static int rtc_wally_alarm_get_supported_fields(const struct device *dev, uint16_t id, uint16_t *mask)
{
    if (id != 0U) {
        return -EINVAL;
    }
    *mask = ALARM_FIELDS;
    return 0;
}

static int rtc_wally_alarm_set_time(const struct device *dev, uint16_t id, uint16_t mask, const struct rtc_time *timeptr)
{
    struct rtc_wally_data *data = dev->data;
    k_spinlock_key_t key;
    int64_t s;
    int rc = 0;

    if (id != 0U) {
        return -EINVAL;
    }
    key = k_spin_lock(&data->lock);
    if (mask == 0U) {                                      /* disable */
        wr(dev, REG_CTRL, CTRL_EN);
        wr(dev, REG_STATUS, 1);
        data->armed = false;
        goto out;
    }
    if (mask != ALARM_FIELDS || timeptr == NULL || !valid(timeptr)) {
        rc = -EINVAL;                                      /* only a full date and time can match */
        goto out;
    }
    s = to_seconds(timeptr);
    if (s < 0 || s <= (int64_t)rd(dev, REG_TIME)) {
        rc = -EINVAL;
        goto out;
    }
    wr(dev, REG_ALARM, (uint32_t)s);
    wr(dev, REG_STATUS, 1);
    data->armed = true;
    wr(dev, REG_CTRL, CTRL_EN | (data->cb != NULL ? CTRL_IE : 0));
    if (rd(dev, REG_TIME) >= (uint32_t)s && !(rd(dev, REG_STATUS) & 1)) {
        wr(dev, REG_CTRL, CTRL_EN);                        /* the time went by while it was written: it can never match */
        data->armed = false;
        rc = -ETIME;
    }
out:
    k_spin_unlock(&data->lock, key);
    return rc;
}

static int rtc_wally_alarm_get_time(const struct device *dev, uint16_t id, uint16_t *mask, struct rtc_time *timeptr)
{
    struct rtc_wally_data *data = dev->data;

    if (id != 0U) {
        return -EINVAL;
    }
    from_seconds(rd(dev, REG_ALARM), timeptr);
    *mask = data->armed ? ALARM_FIELDS : 0U;
    return 0;
}

static int rtc_wally_alarm_is_pending(const struct device *dev, uint16_t id)
{
    struct rtc_wally_data *data = dev->data;
    k_spinlock_key_t key;
    int pending;

    if (id != 0U) {
        return -EINVAL;
    }
    key = k_spin_lock(&data->lock);
    pending = (rd(dev, REG_STATUS) & 1) != 0U;
    if (pending) {
        wr(dev, REG_STATUS, 1);                            /* reading clears it, as the API says */
    }
    k_spin_unlock(&data->lock, key);
    return pending;
}

static int rtc_wally_alarm_set_callback(const struct device *dev, uint16_t id, rtc_alarm_callback callback, void *user_data)
{
    struct rtc_wally_data *data = dev->data;
    k_spinlock_key_t key;

    if (id != 0U) {
        return -EINVAL;
    }
    key = k_spin_lock(&data->lock);
    data->cb = callback;
    data->cb_arg = user_data;
    wr(dev, REG_CTRL, CTRL_EN | ((callback != NULL && data->armed) ? CTRL_IE : 0));
    k_spin_unlock(&data->lock, key);
    return 0;
}

static void rtc_wally_isr(const struct device *dev)
{
    struct rtc_wally_data *data = dev->data;

    if (rd(dev, REG_STATUS) & 1) {
        wr(dev, REG_STATUS, 1);
        data->armed = false;                               /* a one-shot alarm */
        wr(dev, REG_CTRL, CTRL_EN);
        if (data->cb != NULL) {
            data->cb(dev, 0, data->cb_arg);
        }
    }
}
#endif /* CONFIG_RTC_ALARM */

static int rtc_wally_init(const struct device *dev)
{
    const struct rtc_wally_cfg *cfg = dev->config;

    wr(dev, REG_DIV, cfg->div);
    wr(dev, REG_CTRL, CTRL_EN);
#ifdef CONFIG_RTC_ALARM
    cfg->irq_config();
#endif
    return 0;
}

static DEVICE_API(rtc, rtc_wally_api) = {
    .set_time = rtc_wally_set_time,
    .get_time = rtc_wally_get_time,
#ifdef CONFIG_RTC_ALARM
    .alarm_get_supported_fields = rtc_wally_alarm_get_supported_fields,
    .alarm_set_time = rtc_wally_alarm_set_time,
    .alarm_get_time = rtc_wally_alarm_get_time,
    .alarm_is_pending = rtc_wally_alarm_is_pending,
    .alarm_set_callback = rtc_wally_alarm_set_callback,
#endif
};

#ifdef CONFIG_RTC_ALARM
#define RTC_WALLY_IRQ(n)                                                                            \
    static void rtc_wally_irq_config_##n(void)                                                      \
    {                                                                                               \
        IRQ_CONNECT(DT_INST_IRQN(n), DT_INST_IRQ(n, priority), rtc_wally_isr, DEVICE_DT_INST_GET(n), 0); \
        irq_enable(DT_INST_IRQN(n));                                                                \
    }
#else
#define RTC_WALLY_IRQ(n) static void rtc_wally_irq_config_##n(void) {}
#endif

#define RTC_WALLY_INIT(n)                                                                           \
    RTC_WALLY_IRQ(n)                                                                                \
    static const struct rtc_wally_cfg rtc_wally_cfg_##n = {                                         \
        .base = DT_INST_REG_ADDR(n),                                                                \
        .div = DT_INST_PROP(n, clock_frequency) / DT_INST_PROP(n, tick_frequency) - 1U,             \
        .irq_config = rtc_wally_irq_config_##n,                                                     \
    };                                                                                              \
    static struct rtc_wally_data rtc_wally_data_##n;                                                \
    DEVICE_DT_INST_DEFINE(n, rtc_wally_init, NULL, &rtc_wally_data_##n, &rtc_wally_cfg_##n,         \
                          POST_KERNEL, CONFIG_RTC_INIT_PRIORITY, &rtc_wally_api);

DT_INST_FOREACH_STATUS_OKAY(RTC_WALLY_INIT)
