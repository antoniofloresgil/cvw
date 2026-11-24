// SPDX-License-Identifier: GPL-2.0
/* Smcdeleg/Ssccfg on a running kernel: the probe of delegation_build.py as a module (insmod, read dmesg, rmmod).
 * S-mode selects delegated counter 3 through siselect, writes its event (sireg2) and value (sireg), stops it with
 * scountinhibit, reads them back and restores everything.  Without menvcfg.CDE these CSRs trap and insmod oopses. */
#include <linux/bits.h>
#include <linux/module.h>
#include <asm/csr.h>

static int __init wally_smcdeleg_init(void)
{
    unsigned long select, inhibit, value, event, got, stopped, flags;
    bool ok;

    local_irq_save(flags);
    select = csr_read(0x150);   /* siselect */
    inhibit = csr_read(0x120);  /* scountinhibit */
    csr_write(0x150, 0x43);     /* delegated mhpmcounter3 */
    value = csr_read(0x151);    /* sireg */
    event = csr_read(0x152);    /* sireg2 = mhpmevent3 */
    csr_write(0x120, inhibit | BIT(3));
    csr_write(0x152, 1);
    csr_write(0x151, 17);
    got = csr_read(0x151);
    stopped = csr_read(0x120);
    ok = got == 17 && csr_read(0x152) == 1 && (stopped & BIT(3));
    csr_write(0x152, event);
    csr_write(0x151, value);
    csr_write(0x120, inhibit);
    csr_write(0x150, select);
    local_irq_restore(flags);
    if (ok)
        pr_info("WALLY_SMCDELEG_PASS direct_smode_counter_access\n");
    else
        pr_err("WALLY_SMCDELEG_FAIL direct_smode_counter_access got=%lu inhibit=%lu\n", got, stopped);
    return 0;
}

static void __exit wally_smcdeleg_exit(void)
{
}

module_init(wally_smcdeleg_init);
module_exit(wally_smcdeleg_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Wally Smcdeleg/Ssccfg probe");
