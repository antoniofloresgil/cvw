/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Zephyr demo for asic_soc_rv32imac: the kernel runs in Machine mode, the application threads in User mode,
 * and the chip's PMP (16 entries, reloaded by the kernel at every context switch) is the only protection.
 *
 * Part 1 (isolation): threads A and B each own a memory partition in a memory domain of their own.  They
 * run at the same time, sleeping in turn so the kernel switches domains between them, and each checks
 * that its own data survives the other's.
 *
 * Part 2 (faults): a user thread of domain A does, one thread per case, what it must not do.  The PMP
 * refuses the access, the kernel's fatal error handler (below) records the exception cause and returns, and
 * Zephyr aborts only that thread: a load (cause 5) or a store (7) access fault for an address outside its
 * domain (domain B's data, kernel data and code, a peripheral, the RAM's last 8 KiB where the instruction
 * trace buffer lives), an instruction access fault (1) for a jump into data, and a kernel oops for a
 * system call on a kernel object the thread has no permission for.
 *
 * The last line is ZEPHYR OK, or ZEPHYR FAIL and the reason. */
#include <zephyr/kernel.h>
#include <zephyr/app_memory/app_memdomain.h>
#include <zephyr/app_memory/mem_domain.h>
#include <zephyr/sys/printk.h>

#define ROUNDS 3

int main(void);

K_APPMEM_PARTITION_DEFINE(part_a);
K_APPMEM_PARTITION_DEFINE(part_b);

K_APP_BMEM(part_a) static volatile uint32_t a_data;
K_APP_BMEM(part_b) static volatile uint32_t b_data;
K_APP_BMEM(part_a) static volatile uint32_t a_bad;   /* what thread A saw wrong, if anything */
K_APP_BMEM(part_b) static volatile uint32_t b_bad;
K_APP_DMEM(part_a) static uint32_t a_code[2] = { 0x00008067, 0x00008067 };   /* ret: data a user thread jumps to */

static volatile uint32_t kernel_data = 0x600D;       /* outside both partitions: kernel only */
static struct k_mem_domain dom_a, dom_b;
static struct k_thread thread_a, thread_b, thread_f;
static struct k_sem kernel_sem;                      /* a kernel object nobody gave to a user thread */
static volatile unsigned long fault_cause;           /* the handler's findings */
static volatile unsigned int fault_reason, fault_count;

K_THREAD_STACK_DEFINE(stack_a, 1024);
K_THREAD_STACK_DEFINE(stack_b, 1024);
K_THREAD_STACK_DEFINE(stack_f, 1024);

#define UART_THR ((volatile uint8_t *)0x10000000)
#define TRACE_AREA ((volatile uint32_t *)0x8000E000)

void k_sys_fatal_error_handler(unsigned int reason, const struct arch_esf *esf)
{
        unsigned long cause;

        __asm__ volatile("csrr %0, mcause" : "=r"(cause));
        fault_cause = cause;
        fault_reason = reason;
        fault_count++;
        /* returning kills the faulting thread and nothing else */
}

static void worker(void *own, void *other, void *id)
{
        volatile uint32_t *mine = own;
        volatile uint32_t *bad = (uintptr_t)id == 1 ? &a_bad : &b_bad;
        uint32_t n = (uint32_t)(uintptr_t)id;

        for (uint32_t i = 1; i <= ROUNDS; i++) {
                *mine = n * 100 + i;
                k_msleep(5);                              /* the other thread runs, in its own domain */
                if (*mine != n * 100 + i) {
                        *bad = 1;
                }
                printk("%c %u\n", n == 1 ? 'A' : 'B', (unsigned)*mine);
                k_msleep(5);
        }
}

static void faulter(void *p1, void *p2, void *p3)
{
        switch ((uintptr_t)p1) {
        case 0: a_data = 7; break;                                   /* own partition: allowed */
        case 1: b_data = 1; break;                                   /* store into domain B */
        case 2: (void)b_data; break;                                 /* load from domain B */
        case 3: kernel_data = 1; break;                              /* store to kernel data */
        case 4: *(volatile uint32_t *)(void *)main = 0; break;       /* store to kernel code */
        case 5: *UART_THR = 'X'; break;                              /* store to a peripheral */
        case 6: ((void (*)(void))(void *)a_code)(); break;           /* execute data of its own partition */
        case 7: (void)*TRACE_AREA; break;                            /* load from the RAM's trace area */
        case 8: k_sem_give(&kernel_sem); break;                      /* system call on a kernel object */
        }
}

/* the fatal error reason and mcause each case must end with (8: the ecall of the refused system call) */
static const struct { const char *name; uint32_t reason, cause; } cases[] = {
        { "own data", 0, 0 },
        { "store domain B", K_ERR_CPU_EXCEPTION, 7 },
        { "load domain B", K_ERR_CPU_EXCEPTION, 5 },
        { "store kernel data", K_ERR_CPU_EXCEPTION, 7 },
        { "store kernel code", K_ERR_CPU_EXCEPTION, 7 },
        { "store UART", K_ERR_CPU_EXCEPTION, 7 },
        { "exec own data", K_ERR_CPU_EXCEPTION, 1 },
        { "load trace area", K_ERR_CPU_EXCEPTION, 5 },
        { "syscall no permission", K_ERR_KERNEL_OOPS, 8 },
};

static int fail(const char *what, uint32_t a, uint32_t b)
{
        printk("ZEPHYR FAIL %s %u %u\n", what, (unsigned)a, (unsigned)b);
        return 1;
}

int main(void)
{
        k_sem_init(&kernel_sem, 0, 1);
        k_mem_domain_init(&dom_a, 0, NULL);
        k_mem_domain_init(&dom_b, 0, NULL);
        k_mem_domain_add_partition(&dom_a, &part_a);
        k_mem_domain_add_partition(&dom_b, &part_b);

        printk("Zephyr PMP demo\n");

        k_thread_create(&thread_a, stack_a, K_THREAD_STACK_SIZEOF(stack_a), worker, (void *)&a_data, (void *)&b_data,
                        (void *)1, 5, K_USER, K_FOREVER);
        k_thread_create(&thread_b, stack_b, K_THREAD_STACK_SIZEOF(stack_b), worker, (void *)&b_data, (void *)&a_data,
                        (void *)2, 5, K_USER, K_FOREVER);
        k_mem_domain_add_thread(&dom_a, &thread_a);
        k_mem_domain_add_thread(&dom_b, &thread_b);
        k_thread_start(&thread_a);
        k_thread_start(&thread_b);
        k_thread_join(&thread_a, K_FOREVER);
        k_thread_join(&thread_b, K_FOREVER);
        if (a_bad || b_bad) {
                return fail("isolation", a_bad, b_bad);
        }
        printk("isolation ok\n");

        for (uint32_t c = 0; c < ARRAY_SIZE(cases); c++) {
                fault_count = fault_cause = fault_reason = 0;
                k_thread_create(&thread_f, stack_f, K_THREAD_STACK_SIZEOF(stack_f), faulter, (void *)c, NULL, NULL, 5,
                                K_USER, K_FOREVER);
                k_mem_domain_add_thread(&dom_a, &thread_f);
                k_thread_start(&thread_f);
                k_thread_join(&thread_f, K_FOREVER);
                printk("%s %u %u\n", cases[c].name, (unsigned)fault_reason, (unsigned)fault_cause);
                if (c == 0 ? (fault_count != 0 || a_data != 7)
                           : (fault_count != 1 || fault_reason != cases[c].reason || fault_cause != cases[c].cause)) {
                        return fail(cases[c].name, fault_reason, fault_cause);
                }
        }
        if (b_data != 200 + ROUNDS || kernel_data != 0x600D) {
                return fail("data changed", b_data, kernel_data);
        }
        printk("ZEPHYR OK\n");
        return 0;
}
