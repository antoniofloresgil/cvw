/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * The chip's timer and real-time counter under Zephyr: the Counter API (top value with a callback, alarms,
 * capture on a pad), the PWM API on the same four channels, and the RTC API (time, an alarm that wakes the idle
 * thread).  chipsim's zephyr_timer test plays the other side on the pads: it drives edges into GPIO2 for the
 * capture and measures the duty cycles on GPIO0 and GPIO1.  Every check prints one line. */
#include <errno.h>
#include <time.h>
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/counter.h>
#include <zephyr/drivers/pwm.h>
#include <zephyr/drivers/rtc.h>
#include <zephyr/dt-bindings/counter/counter-capture.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/timeutil.h>

static const struct device *const timer = DEVICE_DT_GET(DT_NODELABEL(timer0));
static const struct device *const pwm = DEVICE_DT_GET(DT_NODELABEL(timer0_pwm));
static const struct device *const rtc = DEVICE_DT_GET(DT_NODELABEL(rtc0));

static K_SEM_DEFINE(event, 0, 8);
static volatile uint32_t top_count, alarm_ticks, captured[3];
static volatile int captures;

static int fail(const char *what, int v)
{
    printk("TIMER FAIL %s %d\n", what, v);
    return 1;
}

static void top_cb(const struct device *dev, void *arg)
{
    top_count++;
}

static void alarm_cb(const struct device *dev, uint8_t chan, uint32_t ticks, void *arg)
{
    alarm_ticks = ticks;
    k_sem_give(&event);
}

static void capture_cb(const struct device *dev, uint8_t chan, counter_capture_flags_t flags, uint32_t ticks,
                       void *arg)
{
    if (captures < 3) {
        captured[captures++] = ticks;
    }
    if (captures == 3) {
        k_sem_give(&event);
    }
}

static void rtc_alarm_cb(const struct device *dev, uint16_t id, void *arg)
{
    k_sem_give(&event);
}

/* the three captures in a row, as the differences of the ticks (the counter is free-running to 2^32-1) */
static int capture_run(counter_capture_flags_t flags, uint32_t *d0, uint32_t *d1)
{
    int rc;

    captures = 0;
    k_sem_reset(&event);
    rc = counter_capture_configure(timer, 2, flags, capture_cb, NULL);
    if (rc) {
        return rc;
    }
    rc = counter_enable_capture(timer, 2);
    if (rc) {
        return rc;
    }
    printk("capture ready\n");
    if (k_sem_take(&event, K_MSEC(50)) != 0) {
        counter_disable_capture(timer, 2);
        return -ETIMEDOUT;
    }
    counter_disable_capture(timer, 2);
    *d0 = captured[1] - captured[0];
    *d1 = captured[2] - captured[1];
    return 0;
}

int main(void)
{
    struct counter_alarm_cfg alarm = { .callback = alarm_cb };
    struct counter_top_cfg top = { .ticks = 50000, .callback = top_cb };
    uint32_t a, b, d0, d1;
    int rc;

    if (!device_is_ready(timer) || !device_is_ready(pwm) || !device_is_ready(rtc)) {
        return fail("device not ready", device_is_ready(timer) | device_is_ready(pwm) << 1 | device_is_ready(rtc) << 2);
    }
    printk("timer start\n");

    /* the counter runs, ticks at the clock (prescaler 0) */
    counter_start(timer);
    counter_get_value(timer, &a);
    k_busy_wait(10);
    counter_get_value(timer, &b);
    printk(b > a ? "count ok\n" : "count FAIL\n");
    printk("freq %u\n", counter_get_frequency(timer));

    /* the top value 50000: the callback runs at each wrap, 18432 * 10 ms / 50001 = 3.7 */
    rc = counter_set_top_value(timer, &top);
    if (rc) {
        return fail("top", rc);
    }
    k_msleep(10);
    printk("top %s %u\n", (top_count >= 3 && top_count <= 4) ? "ok" : "FAIL", top_count);

    /* a relative alarm, an absolute one, a cancelled one and one that is already late */
    alarm.ticks = 9216;                                    /* 0.5 ms */
    rc = counter_set_channel_alarm(timer, 0, &alarm);
    if (rc || k_sem_take(&event, K_MSEC(5)) != 0) {
        return fail("relative alarm", rc);
    }
    printk("alarm relative ok\n");
    counter_get_value(timer, &a);
    alarm.ticks = (a + 20000) % (counter_get_top_value(timer) + 1U);
    alarm.flags = COUNTER_ALARM_CFG_ABSOLUTE;
    rc = counter_set_channel_alarm(timer, 1, &alarm);
    if (rc || k_sem_take(&event, K_MSEC(5)) != 0) {
        return fail("absolute alarm", rc);
    }
    printk("alarm absolute %s\n", alarm_ticks == (a + 20000) % 50001U ? "ok" : "FAIL");
    alarm.ticks = 18432;
    alarm.flags = 0;
    counter_set_channel_alarm(timer, 3, &alarm);
    counter_cancel_channel_alarm(timer, 3);
    printk("alarm cancel %s\n", k_sem_take(&event, K_MSEC(3)) != 0 ? "ok" : "FAIL");
    alarm.ticks = 0;
    rc = counter_set_channel_alarm(timer, 3, &alarm);
    printk("alarm late %s\n", rc == -ETIME ? "etime" : "FAIL");
    alarm.flags = COUNTER_ALARM_CFG_EXPIRE_WHEN_LATE;
    k_sem_reset(&event);
    rc = counter_set_channel_alarm(timer, 3, &alarm);
    printk("alarm expire %s\n", (rc == 0 && k_sem_take(&event, K_NO_WAIT) == 0) ? "ok" : "FAIL");

    /* capture on GPIO2, the counter free-running: rising edges 6000 apart, then both edges 4000 and 6000 apart */
    top.ticks = UINT32_MAX;
    top.callback = NULL;
    rc = counter_set_top_value(timer, &top);
    if (rc) {
        return fail("top max", rc);
    }
    rc = capture_run(COUNTER_CAPTURE_RISING_EDGE, &d0, &d1);
    if (rc) {
        return fail("capture rising", rc);
    }
    printk("capture rising %u %u\n", d0, d1);
    rc = capture_run(COUNTER_CAPTURE_BOTH_EDGES, &d0, &d1);
    if (rc) {
        return fail("capture both", rc);
    }
    printk("capture both %u %u\n", d0, d1);

    /* PWM on GPIO0 (25 %) and GPIO1 (inverted, 75 %), a period of 1000 clocks */
    top.ticks = 1;
    rc = counter_set_top_value(timer, &top);               /* the top is the PWM's period: the PWM sets it */
    if (rc) {
        return fail("top pwm", rc);
    }
    rc = pwm_set_cycles(pwm, 0, 1000, 250, 0);
    if (rc) {
        return fail("pwm 0", rc);
    }
    rc = pwm_set_cycles(pwm, 1, 1000, 250, PWM_POLARITY_INVERTED);
    if (rc) {
        return fail("pwm 1", rc);
    }
    printk("pwm on\n");
    k_msleep(3);
    printk("pwm period %s\n", pwm_set_cycles(pwm, 2, 2000, 1000, 0) == -EBUSY ? "busy" : "FAIL");
    printk("pwm channel %s\n", pwm_set_cycles(pwm, 4, 1000, 500, 0) == -EINVAL ? "invalid" : "FAIL");
    alarm.flags = 0;
    alarm.ticks = 100;
    printk("pwm alarm %s\n", counter_set_channel_alarm(timer, 0, &alarm) == -EBUSY ? "busy" : "FAIL");

    /* the RTC: 2026-11-09 12:00:00, a Monday; its seconds run a thousand times faster in the simulation */
    struct rtc_time t = { .tm_sec = 0, .tm_min = 0, .tm_hour = 12, .tm_mday = 9, .tm_mon = 10, .tm_year = 126 };
    struct rtc_time now, later;

    rc = rtc_set_time(rtc, &t);
    if (rc) {
        return fail("rtc set", rc);
    }
    int64_t up0 = k_uptime_get();

    rtc_get_time(rtc, &now);
    printk("rtc %04d-%02d-%02d %02d:%02d:%02d wday %d yday %d\n", now.tm_year + 1900, now.tm_mon + 1, now.tm_mday,
           now.tm_hour, now.tm_min, now.tm_sec, now.tm_wday, now.tm_yday);
    k_msleep(5);
    rtc_get_time(rtc, &later);
    /* the RTC counts a thousand ticks per second here and Zephyr's tick is 1 ms: the same number, give or take one */
    int64_t rtc_s = timeutil_timegm64(rtc_time_to_tm(&later)) - timeutil_timegm64(rtc_time_to_tm(&now));
    int64_t up_ms = k_uptime_get() - up0;

    printk("rtc advanced %s\n", (rtc_s >= 5 && rtc_s - up_ms >= -1 && rtc_s - up_ms <= 1) ? "ok" : "FAIL");
    rtc_get_time(rtc, &now);

    time_t s = timeutil_timegm64(rtc_time_to_tm(&now)) + 3;
    uint16_t all = RTC_ALARM_TIME_MASK_SECOND | RTC_ALARM_TIME_MASK_MINUTE | RTC_ALARM_TIME_MASK_HOUR |
                   RTC_ALARM_TIME_MASK_MONTHDAY | RTC_ALARM_TIME_MASK_MONTH | RTC_ALARM_TIME_MASK_YEAR;

    gmtime_r(&s, rtc_time_to_tm(&later));
    rtc_alarm_set_callback(rtc, 0, rtc_alarm_cb, NULL);
    k_sem_reset(&event);
    rc = rtc_alarm_set_time(rtc, 0, all, &later);
    if (rc) {
        return fail("rtc alarm set", rc);
    }
    /* the main thread sleeps, the idle thread executes wfi, and the alarm interrupt through the PLIC wakes it */
    rc = k_sem_take(&event, K_MSEC(50));
    rtc_get_time(rtc, &now);
    printk("rtc alarm %s at %02d:%02d:%02d\n", rc == 0 ? "ok" : "FAIL", now.tm_hour, now.tm_min, now.tm_sec);
    printk("rtc pending %d\n", rtc_alarm_is_pending(rtc, 0));
    printk("rtc past %s\n", rtc_alarm_set_time(rtc, 0, all, &t) == -EINVAL ? "refused" : "FAIL");
    printk("rtc mask %s\n", rtc_alarm_set_time(rtc, 0, RTC_ALARM_TIME_MASK_SECOND, &later) == -EINVAL ? "refused" : "FAIL");
    printk("TIMER OK\n");
    return 0;
}
