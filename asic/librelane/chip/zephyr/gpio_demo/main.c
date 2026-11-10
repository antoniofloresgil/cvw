/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * GPIO check for asic_soc_rv32imac on the Nexys Video (fpga/src/fpgaChip.sv): the 8 GPIOs are the switches SW0-7 (inputs)
 * and the LEDs LD0-7 (outputs).  First every LED lights in turn, three rounds, so each LD pin shows up in order; then
 * the GPIOs are inputs and the 8 switches are printed every half second (a pin that is an output would read back what it
 * drives, not the switch).  Console at 115200 baud. */
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/sys/printk.h>

static const struct device *const gpio = DEVICE_DT_GET(DT_NODELABEL(gpio0));

int main(void)
{
        if (!device_is_ready(gpio)) {
                printk("GPIO NOT READY\n");
                return 0;
        }
        printk("gpio demo: LEDs LD0..LD7 light in turn, then the switches are printed\n");
        for (int round = 0; round < 3; round++) {
                for (int pin = 0; pin < 8; pin++) {
                        gpio_pin_configure(gpio, pin, GPIO_OUTPUT_HIGH);
                        printk("LD%d on\n", pin);
                        k_msleep(400);
                        gpio_pin_configure(gpio, pin, GPIO_INPUT);
                }
        }
        printk("switches (SW7..SW0), printed every 0.5 s:\n");
        for (;;) {
                int v = 0;
                for (int pin = 0; pin < 8; pin++) {
                        v |= gpio_pin_get(gpio, pin) << pin;
                }
                printk("SW7..0 = ");
                for (int pin = 7; pin >= 0; pin--) {
                        printk("%d", (v >> pin) & 1);
                }
                printk("  (0x%02x)\n", v);
                k_msleep(500);
        }
}
