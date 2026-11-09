# SPDX-License-Identifier: Apache-2.0

zephyr_library()
zephyr_library_sources_ifdef(CONFIG_I2C_WALLY drivers/i2c_wally.c)
zephyr_library_sources_ifdef(CONFIG_WDT_WALLY drivers/wdt_wally.c)
zephyr_library_sources_ifdef(CONFIG_COUNTER_WALLY drivers/timer_wally.c)
zephyr_library_sources_ifdef(CONFIG_RTC_WALLY drivers/rtc_wally.c)
