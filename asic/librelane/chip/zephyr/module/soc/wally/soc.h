/* SPDX-License-Identifier: Apache-2.0 */
#ifndef WALLY_SOC_H
#define WALLY_SOC_H

#include <zephyr/devicetree.h>

/* the peripherals run on the CPU clock (HCLK): the SiFive SPI and PWM drivers ask for it by this name */
#define SIFIVE_PERIPHERAL_CLOCK_FREQUENCY DT_PROP(DT_PATH(cpus, cpu_0), clock_frequency)

#endif /* WALLY_SOC_H */
