/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * The console UART of asic_soc_rv32imac with an interrupt-driven receiver under Zephyr: the host sends three
 * letters, the PLIC raises source 10 (the second interrupt level of Zephyr's multi-level interrupt tables), and
 * the demo echoes the letters in capitals.  chipsim's zephyr_uart_irq test plays the host. */
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/sys/printk.h>

static const struct device *const uart = DEVICE_DT_GET(DT_NODELABEL(uart0));

K_SEM_DEFINE(rx_sem, 0, 3);
static volatile uint8_t rx_buf[3];
static volatile int rx_n;

static void uart_cb(const struct device *dev, void *user)
{
        uint8_t c;

        for (;;) {
                uart_irq_update(dev);                    /* refreshes the IIR that is_pending and rx_ready read */
                if (!uart_irq_is_pending(dev)) {
                        break;
                }
                if (uart_irq_rx_ready(dev)) {
                        while (uart_fifo_read(dev, &c, 1) == 1) {
                                if (rx_n < 3) {
                                        rx_buf[rx_n++] = c;
                                        k_sem_give(&rx_sem);
                                }
                        }
                }
        }
}

int main(void)
{
        printk("uart irq start\n");
        uart_irq_callback_user_data_set(uart, uart_cb, NULL);
        uart_irq_rx_enable(uart);
        printk("uart ready\n");
        for (int i = 0; i < 3; i++) {
                if (k_sem_take(&rx_sem, K_SECONDS(2)) != 0) {
                        printk("UART FAIL rx timeout %d\n", i);
                        return 1;
                }
        }
        uart_irq_rx_disable(uart);
        for (int i = 0; i < 3; i++) {
                printk("%c", rx_buf[i] - 'a' + 'A');
        }
        printk("\nUART IRQ OK\n");
        return 0;
}
