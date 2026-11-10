/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Peripheral demo for asic_soc_rv32imac under Zephyr: the console UART (polled), the GPIO (with interrupts), the SPI
 * flash and the PWM, each through its Zephyr driver.  chipsim's zephyr_peripherals test plays the other side on the pads,
 * and the demo prints one line per step (see test_chip.py). */
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/spi.h>
#include <zephyr/drivers/pwm.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/sys_io.h>

static const struct device *const uart = DEVICE_DT_GET(DT_NODELABEL(uart0));
static const struct device *const gpio = DEVICE_DT_GET(DT_NODELABEL(gpio0));
static const struct device *const spi = DEVICE_DT_GET(DT_NODELABEL(spi0));
static const struct device *const pwm = DEVICE_DT_GET(DT_NODELABEL(pwm0));

static uint8_t rx_buf[3];

/* GPIO interrupts: every pin shares one PLIC line, the driver finds the pin */
static struct gpio_callback gpio_cb_data;
static K_SEM_DEFINE(gpio_sem, 0, 4);
static volatile int gpio_levels[4], gpio_calls;
static volatile bool gpio_level_mode;

static void gpio_cb(const struct device *dev, struct gpio_callback *cb, uint32_t pins)
{
        if (gpio_calls < 4) {
                gpio_levels[gpio_calls] = gpio_pin_get(dev, 4);
        }
        gpio_calls++;
        if (gpio_level_mode) {                 /* a level interrupt fires again at once while the level holds */
                gpio_pin_interrupt_configure(dev, 4, GPIO_INT_DISABLE);
        }
        k_sem_give(&gpio_sem);
}

/* FPGA_TIMING (make APP=periph FPGA_TIMING=1, docs/fpga-chip.md): the chip on the Nexys Video, where GPIO4 is SW4 and a person makes
 * the edges, so the interrupt checks wait 30 s instead of 100 ms.  There is no SPI flash on the board: its read returns zeros. */
#ifdef FPGA_TIMING
#define GPIO_WAIT K_SECONDS(30)
#else
#define GPIO_WAIT K_MSEC(100)
#endif

static int fail(const char *what, int v)
{
        printk("PERIPH FAIL %s %d\n", what, v);
        return 1;
}

int main(void)
{
        if (!device_is_ready(uart) || !device_is_ready(gpio) || !device_is_ready(spi) || !device_is_ready(pwm)) {
                return fail("device not ready (uart gpio spi pwm as bits 0-3)",
                            device_is_ready(uart) | device_is_ready(gpio) << 1 | device_is_ready(spi) << 2 |
                            device_is_ready(pwm) << 3);
        }
        printk("periph start\n");

        /* UART (polled here; ../uart_irq has the interrupt-driven receiver): the host sends three letters and the
         * demo echoes them in capitals */
        printk("uart ready\n");
        for (int i = 0; i < 3; i++) {
                while (uart_poll_in(uart, &rx_buf[i]) != 0) {
                        k_msleep(1);
                }
        }
        for (int i = 0; i < 3; i++) {
                printk("%c", rx_buf[i] - 'a' + 'A');
        }
        printk("\n");

        /* GPIO: pin 4 is an input the test drives, pin 5 an output that follows it, pin 0 an output left high */
        gpio_pin_configure(gpio, 4, GPIO_INPUT);
        gpio_pin_configure(gpio, 5, GPIO_OUTPUT_LOW);
        gpio_pin_configure(gpio, 0, GPIO_OUTPUT_HIGH);
        printk("gpio ready\n");
        k_msleep(50);
        int in = gpio_pin_get(gpio, 4);
        gpio_pin_set(gpio, 5, in);
        printk("gpio in %d\n", in);

        /* SPI: Read (0x03) 4 bytes at address 0 of the flash, which holds "WALY" first */
        uint8_t tx[8] = { 0x03, 0, 0, 0 }, rx[8] = { 0 };
        const struct spi_buf txb = { .buf = tx, .len = 8 }, rxb = { .buf = rx, .len = 8 };
        const struct spi_buf_set txs = { .buffers = &txb, .count = 1 }, rxs = { .buffers = &rxb, .count = 1 };
        struct spi_config cfg = { .frequency = 1000000, .operation = SPI_WORD_SET(8) | SPI_TRANSFER_MSB, .slave = 0 };
        int rc = spi_transceive(spi, &cfg, &txs, &rxs);

        if (rc) {
                return fail("spi", rc);
        }
        printk("spi %c%c%c%c\n", rx[4], rx[5], rx[6], rx[7]);

        /* GPIO interrupts on pin 4: three edges the test drives (falling, rising, falling), each wakes the sleeping main
         * thread, then a level interrupt that the callback disables so that it fires once */
        gpio_init_callback(&gpio_cb_data, gpio_cb, BIT(4));
        gpio_add_callback(gpio, &gpio_cb_data);
        gpio_pin_interrupt_configure(gpio, 4, GPIO_INT_EDGE_BOTH);
        printk("gpio irq ready\n");
        for (int i = 0; i < 3; i++) {
                if (k_sem_take(&gpio_sem, GPIO_WAIT) != 0) {
                        return fail("gpio edge", i);
                }
        }
        gpio_pin_interrupt_configure(gpio, 4, GPIO_INT_DISABLE);
        printk("gpio edges %d%d%d\n", gpio_levels[0], gpio_levels[1], gpio_levels[2]);
        gpio_calls = 0;
        gpio_level_mode = true;
        k_sem_reset(&gpio_sem);
        gpio_pin_interrupt_configure(gpio, 4, GPIO_INT_LEVEL_HIGH);    /* the pin is low: nothing yet */
        printk("gpio level ready\n");
        if (k_sem_take(&gpio_sem, GPIO_WAIT) != 0) {
                return fail("gpio level", 0);
        }
        k_msleep(2);
        printk("gpio level %d %s\n", gpio_levels[0], gpio_calls == 1 ? "once" : "FAIL");

        /* PWM: on GPIO0-3 the PWM is IOF0, whose output enable is still the GPIO's (the pinctrl state selected the
         * function at start-up, the pins must be outputs too) */
        gpio_pin_configure(gpio, 1, GPIO_OUTPUT);
        gpio_pin_configure(gpio, 2, GPIO_OUTPUT);
        /* PWM: 10 us period, pulse 25 % on channel 1 (GPIO1) and 75 % on channel 2 (GPIO2).  The output follows the
         * SiFive FU540 PWM: it is high from the compare match to the end of the period, and the Zephyr driver
         * writes the pulse straight into the comparator, so the pad is high for period - pulse (75 % and 25 %) */
        rc = pwm_set(pwm, 1, PWM_USEC(10), PWM_USEC(10) / 4, 0);
        rc |= pwm_set(pwm, 2, PWM_USEC(10), PWM_USEC(10) * 3 / 4, 0);
        if (rc) {
                return fail("pwm", rc);
        }
        printk("pwm regs gpio oen=%x iof_en=%x iof_sel=%x pwm cfg=%x cmp0=%x cmp1=%x cmp2=%x count=%x\n",
               (unsigned)sys_read32(0x10060008), (unsigned)sys_read32(0x10060038), (unsigned)sys_read32(0x1006003C),
               (unsigned)sys_read32(0x10020000), (unsigned)sys_read32(0x10020020), (unsigned)sys_read32(0x10020024),
               (unsigned)sys_read32(0x10020028), (unsigned)sys_read32(0x10020008));
        printk("pwm set\n");
        k_msleep(200);
        printk("PERIPH OK\n");
        return 0;
}
