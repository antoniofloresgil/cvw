/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * The chip's instruction trace (E-Trace, docs/trace.md) under Zephyr.  The kernel switches the trace on through the
 * Trace Control Interface registers (the hart reaches them with ordinary loads and stores), runs a short workload,
 * switches it off and waits for the encoder and the RAM sink to empty.  The workload is traced_work(): a
 * higher-priority thread is woken by a semaphore three times (three context switches) and the main thread sleeps
 * for a millisecond (the machine timer's interrupt).  The sink's buffer is the last 8 KiB of the RAM, outside
 * Zephyr's 56 KiB, and the test reads it back over JTAG System Bus Access and decodes it against this ELF
 * (testbench/debug/etrace/etracedecode.py).
 *
 * FPGA_DUMP (make APP=trace FPGA_DUMP=1, docs/fpga-chip.md): the chip on the Nexys Video has no JTAG, so after "trace ready"
 * the hart reads the buffer itself through trRamData and prints it, one word per line ("T 0123abcd"), for
 * asic/librelane/chip/trace_decode.py. */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/sys_io.h>

#define TRACE_TE   0x04000000UL        /* hart 0's trace encoder */
#define TRACE_RAM  0x04001000UL        /* and its RAM sink */
#define TE_EMPTY   BIT(3)
#define TE_OVERFLOW BIT(12)            /* trTeInstStallOrOverflow: a packet was dropped */
#define RAM_EMPTY  BIT(3)

static K_SEM_DEFINE(go, 0, 1);
static K_SEM_DEFINE(done, 0, 1);

static void worker(void *a, void *b, void *c)
{
    for (;;) {
        k_sem_take(&go, K_FOREVER);
        k_sem_give(&done);
    }
}

K_THREAD_DEFINE(worker_thread, 512, worker, NULL, NULL, NULL, -1, 0, 0);

__attribute__((noinline)) static void traced_work(void)
{
    for (int i = 0; i < 3; i++) {
        k_sem_give(&go);                       /* the worker has priority: it runs now and wakes this thread */
        k_sem_take(&done, K_FOREVER);
    }
    k_msleep(1);                               /* the timer interrupt ends the sleep */
}

static int wait_for(uintptr_t reg, uint32_t bit)
{
    for (int i = 0; i < 1000; i++) {
        if (sys_read32(reg) & bit) {
            return 0;
        }
    }
    return -1;
}

int main(void)
{
    printk("trace start\n");

    sys_write32(1, TRACE_RAM);                 /* trRamActive */
    sys_write32(0, TRACE_RAM + 0x20);          /* trRamWPLow */
    sys_write32(3, TRACE_RAM);                 /* trRamEnable */
    sys_write32(1, TRACE_TE);                  /* trTeActive */
    sys_write32(0x00010037, TRACE_TE);         /* trace on: baseline, sync by packets */

    traced_work();

    sys_write32(0x00010031, TRACE_TE);         /* trTeEnable 0: flush the encoder */
    int rc = wait_for(TRACE_TE, TE_EMPTY);

    sys_write32(1, TRACE_RAM);                 /* trRamEnable 0: write out what is queued */
    rc |= wait_for(TRACE_RAM, RAM_EMPTY);

    uint32_t te = sys_read32(TRACE_TE);
    uint32_t wp = sys_read32(TRACE_RAM + 0x20);

    printk("trace %s\n", (rc == 0 && !(te & TE_OVERFLOW) && wp != 0 && wp <= 0x2000) ? "ok" : "FAIL");
    printk("trace bytes %u\n", wp & ~1U);
    printk("trace ready\n");
#ifdef FPGA_DUMP
    if (rc == 0) {
        sys_write32(0, TRACE_RAM + 0x28);      /* trRamRPLow */
        for (uint32_t i = 0; i < wp / 4; i++) {
            printk("T %08x\n", sys_read32(TRACE_RAM + 0x40));   /* each read of trRamData moves the read pointer on */
        }
        printk("trace dumped\n");
    }
#endif
    k_sleep(K_FOREVER);                        /* the idle thread executes wfi while the test reads the buffer */
    return 0;
}
