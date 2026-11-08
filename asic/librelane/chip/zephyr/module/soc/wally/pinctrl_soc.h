/* SPDX-License-Identifier: Apache-2.0
 * The pin state of the SiFive pinctrl driver (IOF_EN, IOF_SEL of the GPIO), as the SiFive Freedom SoCs of
 * Zephyr define it (soc/sifive/sifive_freedom/common/pinctrl_soc.h, Antmicro, Apache-2.0). */
#ifndef WALLY_PINCTRL_SOC_H_
#define WALLY_PINCTRL_SOC_H_

#include <zephyr/types.h>

typedef struct pinctrl_soc_pin_t {
        uint8_t pin;
        uint8_t iof;
} pinctrl_soc_pin_t;

#define SIFIVE_DT_PIN(node_id)                                  \
        {                                                       \
                .pin = DT_PROP_BY_IDX(node_id, pinmux, 0),      \
                .iof = DT_PROP_BY_IDX(node_id, pinmux, 1)       \
        },

#define Z_PINCTRL_STATE_PIN_INIT(node_id, prop, idx)            \
        SIFIVE_DT_PIN(DT_PROP_BY_IDX(node_id, prop, idx))

#define Z_PINCTRL_STATE_PINS_INIT(node_id, prop)                \
        { DT_FOREACH_PROP_ELEM(node_id, prop, Z_PINCTRL_STATE_PIN_INIT) }

#endif /* WALLY_PINCTRL_SOC_H_ */
