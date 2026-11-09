/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * GPIO driver for asic_soc_rv32imac (src/uncore/gpio_apb.sv).  The registers are those of the SiFive FE310's GPIO, which
 * Zephyr's gpio_sifive.c drives, but the chip has one interrupt line (PLIC source 3) for the eight pins where that
 * driver expects one per pin: this one has a single handler that reads which pins have a pending condition, as
 * gpio_sifive.c does for one pin.  Structure and register handling follow it (Copyright (c) 2017 Jean-Paul Etienne,
 * Apache-2.0). */
#define DT_DRV_COMPAT wally_gpio

#include <errno.h>
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/irq.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/gpio/gpio_utils.h>
#include <zephyr/sys/sys_io.h>
#include <zephyr/sys/util.h>

#define REG_IN_VAL  0x00
#define REG_IN_EN   0x04
#define REG_OUT_EN  0x08
#define REG_OUT_VAL 0x0C
#define REG_PUE     0x10
#define REG_RISE_IE 0x18
#define REG_RISE_IP 0x1C
#define REG_FALL_IE 0x20
#define REG_FALL_IP 0x24
#define REG_HIGH_IE 0x28
#define REG_HIGH_IP 0x2C
#define REG_LOW_IE  0x30
#define REG_LOW_IP  0x34
#define REG_IOF_EN  0x38
#define REG_IOF_SEL 0x3C
#define REG_INVERT  0x40

struct gpio_wally_cfg {
    struct gpio_driver_config common;      /* first */
    mem_addr_t base;
    void (*irq_config)(void);
};

struct gpio_wally_data {
    struct gpio_driver_data common;        /* first */
    sys_slist_t callbacks;
};

static inline uint32_t rd(const struct device *dev, uint32_t reg)
{
    return sys_read32(((const struct gpio_wally_cfg *)dev->config)->base + reg);
}

static inline void wr(const struct device *dev, uint32_t reg, uint32_t v)
{
    sys_write32(v, ((const struct gpio_wally_cfg *)dev->config)->base + reg);
}

static inline void rmw(const struct device *dev, uint32_t reg, uint32_t clear, uint32_t set)
{
    wr(dev, reg, (rd(dev, reg) & ~clear) | set);
}

static int gpio_wally_configure(const struct device *dev, gpio_pin_t pin, gpio_flags_t flags)
{
    if ((flags & GPIO_SINGLE_ENDED) != 0) {
        return -ENOTSUP;                                   /* no open drain */
    }
    if ((flags & GPIO_PULL_DOWN) != 0) {
        return -ENOTSUP;                                   /* pull-ups only */
    }
    rmw(dev, REG_PUE, BIT(pin), (flags & GPIO_PULL_UP) ? BIT(pin) : 0);
    if ((flags & GPIO_OUTPUT_INIT_HIGH) != 0) {            /* the level before the output is enabled, to avoid glitches */
        rmw(dev, REG_OUT_VAL, 0, BIT(pin));
    }
    if ((flags & GPIO_OUTPUT_INIT_LOW) != 0) {
        rmw(dev, REG_OUT_VAL, BIT(pin), 0);
    }
    rmw(dev, REG_OUT_EN, BIT(pin), (flags & GPIO_OUTPUT) ? BIT(pin) : 0);
    rmw(dev, REG_IN_EN, BIT(pin), (flags & GPIO_INPUT) ? BIT(pin) : 0);
    return 0;
}

static int gpio_wally_port_get_raw(const struct device *dev, gpio_port_value_t *value)
{
    *value = rd(dev, REG_IN_VAL);
    return 0;
}

static int gpio_wally_port_set_masked_raw(const struct device *dev, gpio_port_pins_t mask, gpio_port_value_t value)
{
    rmw(dev, REG_OUT_VAL, mask, value & mask);
    return 0;
}

static int gpio_wally_port_set_bits_raw(const struct device *dev, gpio_port_pins_t mask)
{
    rmw(dev, REG_OUT_VAL, 0, mask);
    return 0;
}

static int gpio_wally_port_clear_bits_raw(const struct device *dev, gpio_port_pins_t mask)
{
    rmw(dev, REG_OUT_VAL, mask, 0);
    return 0;
}

static int gpio_wally_port_toggle_bits(const struct device *dev, gpio_port_pins_t mask)
{
    wr(dev, REG_OUT_VAL, rd(dev, REG_OUT_VAL) ^ mask);
    return 0;
}

static int gpio_wally_pin_interrupt_configure(const struct device *dev, gpio_pin_t pin, enum gpio_int_mode mode,
                                              enum gpio_int_trig trig)
{
    const struct gpio_wally_cfg *cfg = dev->config;
    uint32_t bit = BIT(pin);

    if (mode != GPIO_INT_MODE_DISABLED && (cfg->common.port_pin_mask & bit) == 0U) {
        return -EINVAL;
    }
    rmw(dev, REG_RISE_IE, bit, 0);
    rmw(dev, REG_FALL_IE, bit, 0);
    rmw(dev, REG_HIGH_IE, bit, 0);
    rmw(dev, REG_LOW_IE, bit, 0);
    switch (mode) {
    case GPIO_INT_MODE_DISABLED:
        break;
    case GPIO_INT_MODE_LEVEL:
        if (trig == GPIO_INT_TRIG_HIGH) {
            wr(dev, REG_HIGH_IP, bit);
            rmw(dev, REG_HIGH_IE, 0, bit);
        } else {
            wr(dev, REG_LOW_IP, bit);
            rmw(dev, REG_LOW_IE, 0, bit);
        }
        break;
    case GPIO_INT_MODE_EDGE:
        if ((trig & GPIO_INT_HIGH_1) != 0) {
            wr(dev, REG_RISE_IP, bit);
            rmw(dev, REG_RISE_IE, 0, bit);
        }
        if ((trig & GPIO_INT_LOW_0) != 0) {
            wr(dev, REG_FALL_IP, bit);
            rmw(dev, REG_FALL_IE, 0, bit);
        }
        break;
    default:
        return -ENOTSUP;
    }
    return 0;
}

static int gpio_wally_manage_callback(const struct device *dev, struct gpio_callback *callback, bool set)
{
    struct gpio_wally_data *data = dev->data;

    return gpio_manage_callback(&data->callbacks, callback, set);
}

#ifdef CONFIG_GPIO_GET_DIRECTION
static int gpio_wally_port_get_dir(const struct device *dev, gpio_port_pins_t map, gpio_port_pins_t *inputs,
                                   gpio_port_pins_t *outputs)
{
    const struct gpio_wally_cfg *cfg = dev->config;

    map &= cfg->common.port_pin_mask;
    if (inputs != NULL) {
        *inputs = map & rd(dev, REG_IN_EN);
    }
    if (outputs != NULL) {
        *outputs = map & rd(dev, REG_OUT_EN);
    }
    return 0;
}
#endif

/* One interrupt for every pin: the pins with an enabled condition pending.  The four conditions of a pin are
 * independent (a rising edge sets both rise and high), so all of a pin's are cleared and its callbacks run once;
 * a level condition that still holds sets its flag again at once. */
static void gpio_wally_isr(const struct device *dev)
{
    struct gpio_wally_data *data = dev->data;
    uint32_t pins = (rd(dev, REG_RISE_IP) & rd(dev, REG_RISE_IE)) | (rd(dev, REG_FALL_IP) & rd(dev, REG_FALL_IE)) |
                    (rd(dev, REG_HIGH_IP) & rd(dev, REG_HIGH_IE)) | (rd(dev, REG_LOW_IP) & rd(dev, REG_LOW_IE));

    if (pins == 0U) {
        return;
    }
    wr(dev, REG_RISE_IP, pins);
    wr(dev, REG_FALL_IP, pins);
    wr(dev, REG_HIGH_IP, pins);
    wr(dev, REG_LOW_IP, pins);
    gpio_fire_callbacks(&data->callbacks, dev, pins);
}

static int gpio_wally_init(const struct device *dev)
{
    const struct gpio_wally_cfg *cfg = dev->config;

    wr(dev, REG_IN_EN, 0);
    wr(dev, REG_OUT_EN, 0);
    wr(dev, REG_PUE, 0);
    wr(dev, REG_RISE_IE, 0);
    wr(dev, REG_FALL_IE, 0);
    wr(dev, REG_HIGH_IE, 0);
    wr(dev, REG_LOW_IE, 0);
    wr(dev, REG_IOF_EN, 0);
    wr(dev, REG_IOF_SEL, 0);
    wr(dev, REG_INVERT, 0);
    cfg->irq_config();
    return 0;
}

static DEVICE_API(gpio, gpio_wally_api) = {
    .pin_configure = gpio_wally_configure,
    .port_get_raw = gpio_wally_port_get_raw,
    .port_set_masked_raw = gpio_wally_port_set_masked_raw,
    .port_set_bits_raw = gpio_wally_port_set_bits_raw,
    .port_clear_bits_raw = gpio_wally_port_clear_bits_raw,
    .port_toggle_bits = gpio_wally_port_toggle_bits,
    .pin_interrupt_configure = gpio_wally_pin_interrupt_configure,
    .manage_callback = gpio_wally_manage_callback,
#ifdef CONFIG_GPIO_GET_DIRECTION
    .port_get_direction = gpio_wally_port_get_dir,
#endif
};

#define GPIO_WALLY_INIT(n)                                                                          \
    static void gpio_wally_irq_config_##n(void)                                                     \
    {                                                                                               \
        IRQ_CONNECT(DT_INST_IRQN(n), DT_INST_IRQ(n, priority), gpio_wally_isr, DEVICE_DT_INST_GET(n), 0); \
        irq_enable(DT_INST_IRQN(n));                                                                \
    }                                                                                               \
    static const struct gpio_wally_cfg gpio_wally_cfg_##n = {                                       \
        .common = GPIO_COMMON_CONFIG_FROM_DT_INST(n),                                               \
        .base = DT_INST_REG_ADDR(n),                                                                \
        .irq_config = gpio_wally_irq_config_##n,                                                    \
    };                                                                                              \
    static struct gpio_wally_data gpio_wally_data_##n;                                              \
    DEVICE_DT_INST_DEFINE(n, gpio_wally_init, NULL, &gpio_wally_data_##n, &gpio_wally_cfg_##n,      \
                          PRE_KERNEL_1, CONFIG_GPIO_INIT_PRIORITY, &gpio_wally_api);

DT_INST_FOREACH_STATUS_OKAY(GPIO_WALLY_INIT)
