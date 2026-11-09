/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Driver for the I2C master of asic_soc_rv32imac (src/uncore/mcu/i2c_apb.sv).  One command of the
 * controller is a START, a byte (READ or WRITE) and a STOP, each as flagged and in that order, so a transfer is
 * a series of commands: the address byte with START, then the data bytes, STOP on the last byte of a message
 * that has I2C_MSG_STOP.  The SCL period is 4 * (PRE + 1) clocks.
 *
 * With an `interrupts` property in the devicetree (the chip's PLIC source 17) the calling thread sleeps while a
 * command runs and the controller's interrupt, raised when the command finishes, wakes it: the CPU is free
 * (or in wfi) for the whole byte.  Without it the driver polls STATUS.  A mutex serialises the threads. */
#define DT_DRV_COMPAT wally_i2c

#include <errno.h>
#include <soc.h>
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/drivers/pinctrl.h>
#include <zephyr/irq.h>
#include <zephyr/sys/sys_io.h>

#define REG_PRE    0x00
#define REG_CTRL   0x04
#define REG_DATA   0x08   /* write: byte to send, read: byte received */
#define REG_CMD    0x0C
#define REG_STATUS 0x10

#define CTRL_EN     BIT(0)
#define CTRL_IE     BIT(1)
#define CMD_START   BIT(0)
#define CMD_STOP    BIT(1)
#define CMD_READ    BIT(2)
#define CMD_WRITE   BIT(3)
#define CMD_NACK    BIT(4)
#define STATUS_BUSY BIT(0)
#define STATUS_RXACK BIT(1)   /* the addressed device did not acknowledge the last written byte */
#define STATUS_IF   BIT(2)    /* a command finished; write 1 to clear */

#define WAIT_LOOPS 1000000
#define CMD_TIMEOUT_MS 100

struct i2c_wally_cfg {
    mem_addr_t base;
    uint32_t f_sys;
    uint32_t f_bus;
    const struct pinctrl_dev_config *pcfg;
    void (*irq_config)(void);              /* NULL: no interrupt, poll */
};

struct i2c_wally_data {
    struct k_mutex lock;
    struct k_sem done;                     /* given by the interrupt when a command finishes */
    uint32_t status;                       /* the STATUS the interrupt read */
};

static int i2c_wally_set_speed(const struct device *dev, uint32_t bitrate)
{
    const struct i2c_wally_cfg *cfg = dev->config;
    uint32_t pre = cfg->f_sys / (4U * bitrate);

    pre = pre > 3U ? pre - 1U : 2U;        /* PRE must be at least 2: two synchronizer flops on the pads */
    sys_write32(pre, cfg->base + REG_PRE);
    return 0;
}

static int i2c_wally_configure(const struct device *dev, uint32_t dev_config)
{
    const struct i2c_wally_cfg *cfg = dev->config;

    if (!(dev_config & I2C_MODE_CONTROLLER)) {
        return -ENOTSUP;
    }
    if (dev_config & I2C_ADDR_10_BITS) {
        return -ENOTSUP;
    }
    switch (I2C_SPEED_GET(dev_config)) {
    case I2C_SPEED_STANDARD:
        i2c_wally_set_speed(dev, 100000U);
        break;
    case I2C_SPEED_FAST:
        i2c_wally_set_speed(dev, 400000U);
        break;
    default:
        return -ENOTSUP;
    }
    sys_write32(CTRL_EN, cfg->base + REG_CTRL);
    return 0;
}

/* Run one command and wait until it finishes; returns the STATUS read at the end, or -ETIMEDOUT */
static int i2c_wally_cmd(const struct device *dev, uint32_t cmd)
{
    const struct i2c_wally_cfg *cfg = dev->config;
    struct i2c_wally_data *data = dev->data;
    uint32_t status;

    sys_write32(STATUS_IF, cfg->base + REG_STATUS);       /* clear the previous command's flag */
    if (cfg->irq_config != NULL) {
        k_sem_reset(&data->done);
        sys_write32(CTRL_EN | CTRL_IE, cfg->base + REG_CTRL);
        sys_write32(cmd, cfg->base + REG_CMD);
        if (k_sem_take(&data->done, K_MSEC(CMD_TIMEOUT_MS)) != 0) {
            sys_write32(CTRL_EN, cfg->base + REG_CTRL);
            return -ETIMEDOUT;
        }
        return data->status;
    }
    sys_write32(cmd, cfg->base + REG_CMD);
    for (int i = 0; i < WAIT_LOOPS; i++) {
        status = sys_read32(cfg->base + REG_STATUS);
        if ((status & STATUS_IF) && !(status & STATUS_BUSY)) {
            return status;
        }
    }
    return -ETIMEDOUT;
}

static void i2c_wally_isr(const struct device *dev)
{
    const struct i2c_wally_cfg *cfg = dev->config;
    struct i2c_wally_data *data = dev->data;
    uint32_t status = sys_read32(cfg->base + REG_STATUS);

    if (status & STATUS_IF) {
        sys_write32(STATUS_IF, cfg->base + REG_STATUS);   /* the interrupt is the flag: clear it */
        sys_write32(CTRL_EN, cfg->base + REG_CTRL);
        data->status = status;
        k_sem_give(&data->done);
    }
}

static int i2c_wally_write_msg(const struct device *dev, struct i2c_msg *msg)
{
    const struct i2c_wally_cfg *cfg = dev->config;

    for (uint32_t i = 0; i < msg->len; i++) {
        bool last = (i == msg->len - 1U);
        int st;

        sys_write32(msg->buf[i], cfg->base + REG_DATA);
        st = i2c_wally_cmd(dev, CMD_WRITE | ((last && (msg->flags & I2C_MSG_STOP)) ? CMD_STOP : 0U));
        if (st < 0) {
            return st;
        }
        if (st & STATUS_RXACK) {
            i2c_wally_cmd(dev, CMD_STOP);           /* a NACK ends the transfer */
            return -EIO;
        }
    }
    return 0;
}

static int i2c_wally_read_msg(const struct device *dev, struct i2c_msg *msg)
{
    const struct i2c_wally_cfg *cfg = dev->config;

    for (uint32_t i = 0; i < msg->len; i++) {
        bool last = (i == msg->len - 1U);
        int st = i2c_wally_cmd(dev, CMD_READ | (last ? CMD_NACK : 0U) |
                                    ((last && (msg->flags & I2C_MSG_STOP)) ? CMD_STOP : 0U));

        if (st < 0) {
            return st;
        }
        msg->buf[i] = sys_read32(cfg->base + REG_DATA) & 0xFF;
    }
    return 0;
}

static int i2c_wally_transfer_locked(const struct device *dev, struct i2c_msg *msgs, uint8_t num_msgs, uint16_t addr)
{
    const struct i2c_wally_cfg *cfg = dev->config;

    if (msgs == NULL || num_msgs == 0U) {
        return -EINVAL;
    }
    for (uint8_t m = 0; m < num_msgs; m++) {
        bool read = (msgs[m].flags & I2C_MSG_READ) != 0U;
        int rc;

        if (msgs[m].flags & I2C_MSG_ADDR_10_BITS) {
            return -ENOTSUP;
        }
        if (m == 0U || (msgs[m].flags & I2C_MSG_RESTART)) {      /* START, then the address byte */
            int st;

            sys_write32((addr << 1) | (read ? 1U : 0U), cfg->base + REG_DATA);
            st = i2c_wally_cmd(dev, CMD_START | CMD_WRITE);
            if (st < 0) {
                return st;
            }
            if (st & STATUS_RXACK) {
                i2c_wally_cmd(dev, CMD_STOP);
                return -EIO;
            }
        }
        rc = read ? i2c_wally_read_msg(dev, &msgs[m]) : i2c_wally_write_msg(dev, &msgs[m]);
        if (rc != 0) {
            return rc;
        }
    }
    return 0;
}

static int i2c_wally_transfer(const struct device *dev, struct i2c_msg *msgs, uint8_t num_msgs, uint16_t addr)
{
    struct i2c_wally_data *data = dev->data;
    int rc;

    k_mutex_lock(&data->lock, K_FOREVER);
    rc = i2c_wally_transfer_locked(dev, msgs, num_msgs, addr);
    k_mutex_unlock(&data->lock);
    return rc;
}

static int i2c_wally_init(const struct device *dev)
{
    const struct i2c_wally_cfg *cfg = dev->config;
    struct i2c_wally_data *data = dev->data;
    int rc = pinctrl_apply_state(cfg->pcfg, PINCTRL_STATE_DEFAULT);

    k_mutex_init(&data->lock);
    k_sem_init(&data->done, 0, 1);
    if (cfg->irq_config != NULL) {
        cfg->irq_config();
    }

    if (rc < 0) {
        return rc;
    }
    /* the devicetree's clock-frequency: 400 kHz is Fast mode, anything else Standard */
    return i2c_wally_configure(dev, I2C_MODE_CONTROLLER |
                                    I2C_SPEED_SET(cfg->f_bus == 400000U ? I2C_SPEED_FAST : I2C_SPEED_STANDARD));
}

static DEVICE_API(i2c, i2c_wally_api) = {
    .configure = i2c_wally_configure,
    .transfer = i2c_wally_transfer,
};

#define I2C_WALLY_IRQ(n)                                                                           \
    COND_CODE_1(DT_INST_NODE_HAS_PROP(n, interrupts),                                              \
        (static void i2c_wally_irq_config_##n(void)                                                \
         {                                                                                         \
             IRQ_CONNECT(DT_INST_IRQN(n), DT_INST_IRQ(n, priority), i2c_wally_isr,                 \
                         DEVICE_DT_INST_GET(n), 0);                                                \
             irq_enable(DT_INST_IRQN(n));                                                          \
         }),                                                                                       \
        ())

#define I2C_WALLY_INIT(n)                                                                          \
    PINCTRL_DT_INST_DEFINE(n);                                                                     \
    I2C_WALLY_IRQ(n)                                                                               \
    static const struct i2c_wally_cfg i2c_wally_cfg_##n = {                                        \
        .base = DT_INST_REG_ADDR(n),                                                               \
        .f_sys = SIFIVE_PERIPHERAL_CLOCK_FREQUENCY,                                                \
        .f_bus = DT_INST_PROP(n, clock_frequency),                                                 \
        .pcfg = PINCTRL_DT_INST_DEV_CONFIG_GET(n),                                                 \
        .irq_config = COND_CODE_1(DT_INST_NODE_HAS_PROP(n, interrupts), (i2c_wally_irq_config_##n), (NULL)), \
    };                                                                                             \
    static struct i2c_wally_data i2c_wally_data_##n;                                               \
    I2C_DEVICE_DT_INST_DEFINE(n, i2c_wally_init, NULL, &i2c_wally_data_##n, &i2c_wally_cfg_##n,    \
                              POST_KERNEL, CONFIG_I2C_INIT_PRIORITY, &i2c_wally_api);

DT_INST_FOREACH_STATUS_OKAY(I2C_WALLY_INIT)
