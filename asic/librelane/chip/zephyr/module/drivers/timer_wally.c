/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Drivers for the general-purpose timer of asic_soc_rv32imac (src/uncore/mcu/timer_apb.sv): one 32-bit up counter,
 * a 16-bit prescaler, an auto-reload value (ARR, the counter's top) and four channels that are each a compare or an
 * input capture.  A channel compares when it is a counter alarm or a PWM output and captures when it is a capture
 * input; its pad is GPIO0-3 (IOF1).
 *
 *  - wally,timer      the Counter API: start/stop, value, top value with a callback at the wrap, alarms on the four
 *                     channels, and capture on the pads (rising, falling or both edges, single shot or continuous)
 *  - wally,timer-pwm  the PWM API on the same channels (child node of the timer): the output is high while the
 *                     counter is below the pulse, the period is the top value plus one
 *
 * The counter, the prescaler, the top value and the channels are shared, and the two drivers share their state: a
 * channel serves one use at a time (-EBUSY otherwise), and the period of the PWM, the top value of the counter, can
 * only change while no other channel is in use.  Stopping the counter stops the PWM outputs. */
#define DT_DRV_COMPAT wally_timer

#include <errno.h>
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/irq.h>
#include <zephyr/spinlock.h>
#include <zephyr/drivers/counter.h>
#include <zephyr/drivers/pwm.h>
#include <zephyr/drivers/pinctrl.h>
#include <zephyr/dt-bindings/counter/counter-capture.h>
#include <zephyr/sys/sys_io.h>

#define REG_CTRL   0x00
#define REG_PSC    0x04
#define REG_ARR    0x08
#define REG_CNT    0x0C
#define REG_STATUS 0x10
#define REG_IE     0x14
#define REG_CCR(x) (0x20 + 4 * (x))
#define REG_CCFG(x) (0x40 + 4 * (x))

#define CTRL_EN       BIT(0)
#define STATUS_TOP    BIT(0)
#define STATUS_CH(x)  BIT(1 + (x))
#define CCFG_CAPTURE  BIT(0)
#define CCFG_RISING   BIT(1)
#define CCFG_FALLING  BIT(2)
#define CCFG_INVERT   BIT(3)
#define CHANNELS      4

enum owner { FREE, ALARM, CAPTURE, PWM };

struct timer_wally_cfg {
    struct counter_config_info info;      /* first: the Counter API reads it */
    mem_addr_t base;
    uint16_t prescaler;
    void (*irq_config)(void);
};

struct timer_wally_data {
    struct k_spinlock lock;
    counter_top_callback_t top_cb;
    void *top_arg;
    enum owner owner[CHANNELS];
    struct {
        counter_alarm_callback_t alarm_cb;
        void *alarm_arg;
        counter_capture_cb_t capture_cb;
        void *capture_arg;
        counter_capture_flags_t capture_flags;
    } ch[CHANNELS];
};

static inline uint32_t rd(const struct device *dev, uint32_t reg)
{
    return sys_read32(((const struct timer_wally_cfg *)dev->config)->base + reg);
}

static inline void wr(const struct device *dev, uint32_t reg, uint32_t v)
{
    sys_write32(v, ((const struct timer_wally_cfg *)dev->config)->base + reg);
}

static void ie_set(const struct device *dev, uint32_t bits, bool on)
{
    uint32_t ie = rd(dev, REG_IE);

    wr(dev, REG_IE, on ? (ie | bits) : (ie & ~bits));
}

static bool others_busy(const struct timer_wally_data *data, int except)
{
    for (int i = 0; i < CHANNELS; i++) {
        if (i != except && data->owner[i] != FREE) {
            return true;
        }
    }
    return false;
}

static int timer_wally_start(const struct device *dev)
{
    wr(dev, REG_CTRL, CTRL_EN);
    return 0;
}

static int timer_wally_stop(const struct device *dev)
{
    wr(dev, REG_CTRL, 0);
    return 0;
}

static int timer_wally_get_value(const struct device *dev, uint32_t *ticks)
{
    *ticks = rd(dev, REG_CNT);
    return 0;
}

static int timer_wally_set_value(const struct device *dev, uint32_t ticks)
{
    if (ticks > rd(dev, REG_ARR)) {
        return -EINVAL;
    }
    wr(dev, REG_CNT, ticks);
    return 0;
}

static int timer_wally_reset(const struct device *dev)
{
    wr(dev, REG_CNT, 0);
    return 0;
}

static int timer_wally_set_alarm(const struct device *dev, uint8_t chan, const struct counter_alarm_cfg *alarm)
{
    struct timer_wally_data *data = dev->data;
    k_spinlock_key_t key;
    uint64_t span, target, dist, elapsed;
    uint32_t before, now;

    if (chan >= CHANNELS) {
        return -ENOTSUP;
    }
    if (alarm->callback == NULL) {
        return -EINVAL;
    }
    key = k_spin_lock(&data->lock);
    if (data->owner[chan] != FREE) {
        k_spin_unlock(&data->lock, key);
        return -EBUSY;
    }
    span = (uint64_t)rd(dev, REG_ARR) + 1U;                /* the counter counts 0..ARR */
    if (alarm->ticks >= span) {
        k_spin_unlock(&data->lock, key);
        return -EINVAL;
    }
    before = rd(dev, REG_CNT);
    target = (alarm->flags & COUNTER_ALARM_CFG_ABSOLUTE) ? alarm->ticks : (before + (uint64_t)alarm->ticks) % span;
    data->ch[chan].alarm_cb = alarm->callback;
    data->ch[chan].alarm_arg = alarm->user_data;
    data->owner[chan] = ALARM;
    wr(dev, REG_CCFG(chan), 0);
    wr(dev, REG_CCR(chan), (uint32_t)target);
    wr(dev, REG_STATUS, STATUS_CH(chan));
    ie_set(dev, STATUS_CH(chan), true);

    /* late: the counter went past the target between reading it and writing the compare value */
    now = rd(dev, REG_CNT);
    dist = (target + span - before) % span;
    elapsed = ((uint64_t)now + span - before) % span;
    if (dist <= elapsed && !(rd(dev, REG_STATUS) & STATUS_CH(chan))) {
        ie_set(dev, STATUS_CH(chan), false);
        wr(dev, REG_STATUS, STATUS_CH(chan));
        data->owner[chan] = FREE;
        k_spin_unlock(&data->lock, key);
        if (alarm->flags & COUNTER_ALARM_CFG_EXPIRE_WHEN_LATE) {
            alarm->callback(dev, chan, (uint32_t)target, alarm->user_data);
            return 0;
        }
        return -ETIME;
    }
    k_spin_unlock(&data->lock, key);
    return 0;
}

static int timer_wally_cancel_alarm(const struct device *dev, uint8_t chan)
{
    struct timer_wally_data *data = dev->data;
    k_spinlock_key_t key;

    if (chan >= CHANNELS) {
        return -ENOTSUP;
    }
    key = k_spin_lock(&data->lock);
    if (data->owner[chan] == ALARM) {
        ie_set(dev, STATUS_CH(chan), false);
        wr(dev, REG_STATUS, STATUS_CH(chan));
        data->owner[chan] = FREE;
    }
    k_spin_unlock(&data->lock, key);
    return 0;
}

static int timer_wally_set_top_value(const struct device *dev, const struct counter_top_cfg *cfg)
{
    struct timer_wally_data *data = dev->data;
    k_spinlock_key_t key;
    int rc = 0;

    key = k_spin_lock(&data->lock);
    if (others_busy(data, -1)) {
        rc = -EBUSY;                                       /* an alarm, a capture or a PWM channel is using the counter */
        goto out;
    }
    if (cfg->ticks == 0U) {
        rc = -EINVAL;
        goto out;
    }
    data->top_cb = cfg->callback;
    data->top_arg = cfg->user_data;
    wr(dev, REG_ARR, cfg->ticks);
    if (!(cfg->flags & COUNTER_TOP_CFG_DONT_RESET)) {
        wr(dev, REG_CNT, 0);
    } else if (rd(dev, REG_CNT) > cfg->ticks) {            /* it would count on to 2^32 before the wrap */
        if (cfg->flags & COUNTER_TOP_CFG_RESET_WHEN_LATE) {
            wr(dev, REG_CNT, 0);
        }
        rc = -ETIME;
    }
    wr(dev, REG_STATUS, STATUS_TOP);
    ie_set(dev, STATUS_TOP, cfg->callback != NULL);
out:
    k_spin_unlock(&data->lock, key);
    return rc;
}

static uint32_t timer_wally_get_pending_int(const struct device *dev)
{
    return (rd(dev, REG_STATUS) & rd(dev, REG_IE)) != 0U;
}

static uint32_t timer_wally_get_top_value(const struct device *dev)
{
    return rd(dev, REG_ARR);
}

#ifdef CONFIG_COUNTER_CAPTURE
static int timer_wally_capture_configure(const struct device *dev, uint8_t chan, counter_capture_flags_t flags,
                                         counter_capture_cb_t cb, void *user_data)
{
    struct timer_wally_data *data = dev->data;
    k_spinlock_key_t key;
    int rc = 0;

    if (chan >= CHANNELS) {
        return -ENOTSUP;
    }
    if (cb == NULL || (flags & COUNTER_CAPTURE_BOTH_EDGES) == 0U) {
        return -EINVAL;
    }
    key = k_spin_lock(&data->lock);
    if (data->owner[chan] != FREE) {
        rc = -EBUSY;
    } else {
        data->ch[chan].capture_cb = cb;
        data->ch[chan].capture_arg = user_data;
        data->ch[chan].capture_flags = flags;
    }
    k_spin_unlock(&data->lock, key);
    return rc;
}

static int timer_wally_enable_capture(const struct device *dev, uint8_t chan)
{
    struct timer_wally_data *data = dev->data;
    k_spinlock_key_t key;
    counter_capture_flags_t flags;
    int rc = 0;

    if (chan >= CHANNELS) {
        return -ENOTSUP;
    }
    key = k_spin_lock(&data->lock);
    flags = data->ch[chan].capture_flags;
    if (data->ch[chan].capture_cb == NULL) {
        rc = -EINVAL;                                      /* not configured */
    } else if (data->owner[chan] != FREE) {
        rc = -EBUSY;
    } else {
        data->owner[chan] = CAPTURE;
        wr(dev, REG_CCFG(chan), CCFG_CAPTURE | ((flags & COUNTER_CAPTURE_RISING_EDGE) ? CCFG_RISING : 0) |
                                    ((flags & COUNTER_CAPTURE_FALLING_EDGE) ? CCFG_FALLING : 0));
        wr(dev, REG_STATUS, STATUS_CH(chan));
        ie_set(dev, STATUS_CH(chan), true);
    }
    k_spin_unlock(&data->lock, key);
    return rc;
}

static int timer_wally_disable_capture(const struct device *dev, uint8_t chan)
{
    struct timer_wally_data *data = dev->data;
    k_spinlock_key_t key;

    if (chan >= CHANNELS) {
        return -ENOTSUP;
    }
    key = k_spin_lock(&data->lock);
    if (data->owner[chan] == CAPTURE) {
        ie_set(dev, STATUS_CH(chan), false);
        wr(dev, REG_CCFG(chan), 0);
        wr(dev, REG_STATUS, STATUS_CH(chan));
        data->owner[chan] = FREE;
    }
    k_spin_unlock(&data->lock, key);
    return 0;
}

#endif /* CONFIG_COUNTER_CAPTURE */

static void timer_wally_isr(const struct device *dev)
{
    struct timer_wally_data *data = dev->data;
    uint32_t pending = rd(dev, REG_STATUS) & rd(dev, REG_IE);

    wr(dev, REG_STATUS, pending);
    if ((pending & STATUS_TOP) && data->top_cb != NULL) {
        data->top_cb(dev, data->top_arg);
    }
    for (int i = 0; i < CHANNELS; i++) {
        if (!(pending & STATUS_CH(i))) {
            continue;
        }
        if (data->owner[i] == ALARM) {
            counter_alarm_callback_t cb = data->ch[i].alarm_cb;
            void *arg = data->ch[i].alarm_arg;

            ie_set(dev, STATUS_CH(i), false);                /* an alarm fires once */
            data->owner[i] = FREE;
            cb(dev, i, rd(dev, REG_CCR(i)), arg);
        } else if (data->owner[i] == CAPTURE) {
            uint32_t ticks = rd(dev, REG_CCR(i));
            counter_capture_flags_t flags = data->ch[i].capture_flags;

            if (flags & COUNTER_CAPTURE_SINGLE_SHOT) {
                ie_set(dev, STATUS_CH(i), false);
                wr(dev, REG_CCFG(i), 0);
                data->owner[i] = FREE;
            }
            data->ch[i].capture_cb(dev, i, flags, ticks, data->ch[i].capture_arg);
        }
    }
}

static int timer_wally_init(const struct device *dev)
{
    const struct timer_wally_cfg *cfg = dev->config;

    wr(dev, REG_CTRL, 0);
    wr(dev, REG_PSC, cfg->prescaler);
    wr(dev, REG_IE, 0);
    wr(dev, REG_STATUS, 0x1F);
    for (int i = 0; i < CHANNELS; i++) {
        wr(dev, REG_CCFG(i), 0);
    }
    cfg->irq_config();
    return 0;
}

static DEVICE_API(counter, timer_wally_api) = {
    .start = timer_wally_start,
    .stop = timer_wally_stop,
    .get_value = timer_wally_get_value,
    .set_value = timer_wally_set_value,
    .reset = timer_wally_reset,
    .set_alarm = timer_wally_set_alarm,
    .cancel_alarm = timer_wally_cancel_alarm,
    .set_top_value = timer_wally_set_top_value,
    .get_pending_int = timer_wally_get_pending_int,
    .get_top_value = timer_wally_get_top_value,
#ifdef CONFIG_COUNTER_CAPTURE
    .capture_configure = timer_wally_capture_configure,
    .enable_capture = timer_wally_enable_capture,
    .disable_capture = timer_wally_disable_capture,
#endif
};

#define TIMER_WALLY_INIT(n)                                                                         \
    static void timer_wally_irq_config_##n(void)                                                    \
    {                                                                                               \
        IRQ_CONNECT(DT_INST_IRQN(n), DT_INST_IRQ(n, priority), timer_wally_isr, DEVICE_DT_INST_GET(n), 0); \
        irq_enable(DT_INST_IRQN(n));                                                                \
    }                                                                                               \
    static const struct timer_wally_cfg timer_wally_cfg_##n = {                                     \
        .info = {                                                                                   \
            .freq = DT_INST_PROP(n, clock_frequency) / (DT_INST_PROP(n, prescaler) + 1U),           \
            .max_top_value = UINT32_MAX,                                                            \
            .flags = COUNTER_CONFIG_INFO_COUNT_UP,                                                  \
            .channels = CHANNELS,                                                                   \
        },                                                                                          \
        .base = DT_INST_REG_ADDR(n),                                                                \
        .prescaler = DT_INST_PROP(n, prescaler),                                                    \
        .irq_config = timer_wally_irq_config_##n,                                                   \
    };                                                                                              \
    static struct timer_wally_data timer_wally_data_##n;                                            \
    DEVICE_DT_INST_DEFINE(n, timer_wally_init, NULL, &timer_wally_data_##n, &timer_wally_cfg_##n,   \
                          POST_KERNEL, CONFIG_COUNTER_INIT_PRIORITY, &timer_wally_api);

DT_INST_FOREACH_STATUS_OKAY(TIMER_WALLY_INIT)

/* ---- PWM: the same channels as outputs ---- */
#ifdef CONFIG_PWM_WALLY
#undef DT_DRV_COMPAT
#define DT_DRV_COMPAT wally_timer_pwm

struct pwm_wally_cfg {
    const struct device *timer;
    const struct pinctrl_dev_config *pcfg;
};

static int pwm_wally_set_cycles(const struct device *dev, uint32_t channel, uint32_t period, uint32_t pulse,
                                pwm_flags_t flags)
{
    const struct pwm_wally_cfg *cfg = dev->config;
    const struct device *t = cfg->timer;
    struct timer_wally_data *data = t->data;
    k_spinlock_key_t key;
    int rc = 0;

    if (channel >= CHANNELS || period == 0U || pulse > period) {
        return -EINVAL;
    }
    if (flags & ~PWM_POLARITY_MASK) {
        return -ENOTSUP;
    }
    key = k_spin_lock(&data->lock);
    if (data->owner[channel] == ALARM || data->owner[channel] == CAPTURE) {
        rc = -EBUSY;
        goto out;
    }
    if (rd(t, REG_ARR) != period - 1U) {
        if (others_busy(data, channel) || data->top_cb != NULL) {
            rc = -EBUSY;                                   /* the period is shared */
            goto out;
        }
        wr(t, REG_CNT, 0);
        wr(t, REG_ARR, period - 1U);
    }
    wr(t, REG_CCFG(channel), (flags & PWM_POLARITY_INVERTED) ? CCFG_INVERT : 0);
    wr(t, REG_CCR(channel), pulse);                        /* high while the counter is below it; pulse == period: always */
    data->owner[channel] = PWM;
    wr(t, REG_CTRL, CTRL_EN);
out:
    k_spin_unlock(&data->lock, key);
    return rc;
}

static int pwm_wally_get_cycles_per_sec(const struct device *dev, uint32_t channel, uint64_t *cycles)
{
    const struct pwm_wally_cfg *cfg = dev->config;
    const struct timer_wally_cfg *tcfg = cfg->timer->config;

    if (channel >= CHANNELS) {
        return -EINVAL;
    }
    *cycles = tcfg->info.freq;
    return 0;
}

static int pwm_wally_init(const struct device *dev)
{
    const struct pwm_wally_cfg *cfg = dev->config;

    if (!device_is_ready(cfg->timer)) {
        return -ENODEV;
    }
    return pinctrl_apply_state(cfg->pcfg, PINCTRL_STATE_DEFAULT);
}

static DEVICE_API(pwm, pwm_wally_api) = {
    .set_cycles = pwm_wally_set_cycles,
    .get_cycles_per_sec = pwm_wally_get_cycles_per_sec,
};

#define PWM_WALLY_INIT(n)                                                                           \
    PINCTRL_DT_INST_DEFINE(n);                                                                      \
    static const struct pwm_wally_cfg pwm_wally_cfg_##n = {                                         \
        .timer = DEVICE_DT_GET(DT_INST_PARENT(n)),                                                  \
        .pcfg = PINCTRL_DT_INST_DEV_CONFIG_GET(n),                                                  \
    };                                                                                              \
    DEVICE_DT_INST_DEFINE(n, pwm_wally_init, NULL, NULL, &pwm_wally_cfg_##n, POST_KERNEL,           \
                          CONFIG_PWM_INIT_PRIORITY, &pwm_wally_api);

DT_INST_FOREACH_STATUS_OKAY(PWM_WALLY_INIT)
#endif /* CONFIG_PWM_WALLY */
