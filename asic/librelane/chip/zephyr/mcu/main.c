/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * MCU peripherals of asic_soc_rv32imac under Zephyr: the I2C master writes a byte to a device at 0x50 and reads
 * one back, then the watchdog is armed, fed three times and left to reset the chip.  chipsim's zephyr_mcu test
 * plays the I2C device on the pads and sees the bootloader start again after the watchdog's reset. */
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/drivers/watchdog.h>
#include <zephyr/sys/printk.h>

static const struct device *const i2c = DEVICE_DT_GET(DT_NODELABEL(i2c0));
static const struct device *const wdt = DEVICE_DT_GET(DT_NODELABEL(wdt0));

static int fail(const char *what, int v)
{
    printk("MCU FAIL %s %d\n", what, v);
    return 1;
}

int main(void)
{
    if (!device_is_ready(i2c) || !device_is_ready(wdt)) {
        return fail("device not ready", device_is_ready(i2c) | device_is_ready(wdt) << 1);
    }
    printk("mcu start\n");

    uint8_t out = 0x5A, in = 0;
    int rc = i2c_write(i2c, &out, 1, 0x50);

    if (rc) {
        return fail("i2c write", rc);
    }
    printk("i2c write ok\n");
    rc = i2c_read(i2c, &in, 1, 0x50);
    if (rc) {
        return fail("i2c read", rc);
    }
    printk("i2c read %02x\n", in);
    rc = i2c_write(i2c, &out, 1, 0x51);               /* nobody answers at 0x51: a NACK */
    printk("i2c nack %d\n", rc);

    /* 200 ms to the reset: fed every 50 ms three times, then left alone */
    struct wdt_timeout_cfg tcfg = { .window = { .min = 0, .max = 200 }, .flags = WDT_FLAG_RESET_SOC };
    int ch = wdt_install_timeout(wdt, &tcfg);

    if (ch < 0) {
        return fail("wdt install", ch);
    }
    rc = wdt_setup(wdt, 0);
    if (rc) {
        return fail("wdt setup", rc);
    }
    for (int i = 0; i < 3; i++) {
        k_msleep(50);
        wdt_feed(wdt, ch);
    }
    printk("wdt fed\n");
    k_msleep(1000);                                    /* the reset comes within 200 ms */
    return fail("wdt did not reset", 0);
}
