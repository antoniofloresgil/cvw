// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
/*
 * roickpt: checkpoints of the SimPoint intervals of a region of interest, in full-system QEMU (one hart), for Wally.
 * Counts instructions exactly as roibbv does (block granularity, from the HINT slti x0, x0, 0x7a1), and at the start
 * of each chosen interval k (instruction roi_start + k * interval - warmup; later, at the first block that is not in
 * M-mode, if the hart is in OpenSBI then) writes <outdir>/<k>/:
 *   ram.bin    the RAM (ram=<MiB> from 0x80000000) in the testbench's format (64-bit words, bytes reversed, as linux/Makefile)
 *   state.txt  "<name> <hex value>" for the registers, the CSRs and the CLINT, PLIC and UART registers (see dump_devices)
 *   info.txt   interval, instruction counts, warm-up
 * then stops QEMU after the last one.  mkrestore.py makes the restore program (bootmem.bin) from state.txt.
 * QEMU does not show stimecmp to plugins: at the first supervisor timer interrupt after a checkpoint, when mtime has just
 * reached stimecmp, it appends "stimecmp <mtime>" to that checkpoint's state.txt (and runs on until it has one for each).
 * With trace=<n>,tracefile=<file> it instead goes on after the last checkpoint and writes the next n instructions it
 * executes, one hex PC per line, and "T I <pc>" / "T E <pc>" at each interrupt / exception (the PC of the next
 * instruction / of the faulting one), the format of the testbench's +PC_TRACE, to compare the two (drift.py).
 *   qemu-system-riscv64 ... -icount shift=0,sleep=off -plugin ./libroickpt.so,interval=10000000,points=app.simpoints,outdir=ckpt
 * Written for Wally's checkpoint study (no code from QEMU's contrib/plugins).
 */
#include <errno.h>
#include <glib.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <qemu-plugin.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

#define ROI_START 0x7a102013u  /* slti x0, x0, 0x7a1 */
#define ROI_END   0x7a202013u  /* slti x0, x0, 0x7a2 */
#define RAM_BASE  0x80000000ull
#define CLINT     0x02000000ull
#define PLIC      0x0c000000ull
#define UART      0x10000000ull
#define PLIC_SRC  64   /* sources saved (QEMU virt has 95; Wally's buildroot configuration 53) */

typedef struct { const char *name; struct qemu_plugin_register *h; } Reg;

static GArray *regs;            /* Reg: every register QEMU describes */
static struct qemu_plugin_register *pc_reg, *priv_reg;
static uint64_t total, roi_start_insn, roi_insns, interval = 10000000, warmup, ram_mib = 256;
static int roi;
static uint64_t *targets;       /* interval numbers, ascending */
static size_t ntargets, next_target;
static char *outdir, *points, *tracefile;
static uint64_t trace_n, traced;  /* trace=<n>: instructions still to write after the last checkpoint */
static FILE *tf;
static int tracing;
static struct qemu_plugin_register *scause_reg;
static GPtrArray *pending;      /* state.txt files still waiting for their stimecmp */
/* notimer=1: at the start of the region clear mie.STIE and MTIE (as XiangShan's NEMU does before the workload): no timer
 * interrupts in the region unless the kernel enables them again (it does when it programs a timer: counted below) */
static int notimer;
static struct qemu_plugin_register *mie_reg;
static uint64_t roi_interrupts;
static void timer_off(void)
{
    GByteArray *buf = g_byte_array_new();
    uint64_t v = 0;
    if (!mie_reg || !qemu_plugin_read_register(mie_reg, buf)) { fputs("no mie register\n", stderr); _exit(1); }
    memcpy(&v, buf->data, buf->len < 8 ? buf->len : 8);
    v &= ~((1ull << 5) | (1ull << 7));
    g_byte_array_set_size(buf, 0);
    g_byte_array_append(buf, (const guint8 *)&v, 8);
    if (!qemu_plugin_write_register(mie_reg, buf)) { fputs("mie write failed\n", stderr); _exit(1); }
    g_byte_array_free(buf, TRUE);
}
static uint64_t roi_end_total;  /* instruction count at the end of the region, once all checkpoints were taken */
static int irq_seen;            /* an interrupt was taken: look at scause in the handler's first block */

static uint64_t reg_value(struct qemu_plugin_register *h, int *size)
{
    GByteArray *buf = g_byte_array_new();
    uint64_t v = 0;
    if (!qemu_plugin_read_register(h, buf)) { fputs("roickpt: register read failed\n", stderr); _exit(1); }
    memcpy(&v, buf->data, buf->len < 8 ? buf->len : 8);  /* little-endian target and host */
    if (size) *size = buf->len;
    g_byte_array_free(buf, TRUE);
    return v;
}

static uint64_t mem_read(uint64_t addr, size_t len)
{
    GByteArray *buf = g_byte_array_new();
    uint64_t v = 0;
    if (qemu_plugin_read_memory_hwaddr(addr, buf, len) != QEMU_PLUGIN_HWADDR_OPERATION_OK) {
        fprintf(stderr, "roickpt: read of 0x%" PRIx64 " failed\n", addr);
        _exit(1);
    }
    memcpy(&v, buf->data, len);
    g_byte_array_free(buf, TRUE);
    return v;
}

static void mem_write1(uint64_t addr, uint8_t value)
{
    GByteArray *buf = g_byte_array_new();
    g_byte_array_append(buf, &value, 1);
    qemu_plugin_write_memory_hwaddr(addr, buf);
    g_byte_array_free(buf, TRUE);
}

/* Device registers that Linux and OpenSBI have set up, read only where reading has no side effect. */
static void dump_devices(FILE *f)
{
    fprintf(f, "clint.msip %" PRIx64 "\n", mem_read(CLINT, 4));
    fprintf(f, "clint.mtimecmp %" PRIx64 "\n", mem_read(CLINT + 0x4000, 8));
    fprintf(f, "clint.mtime %" PRIx64 "\n", mem_read(CLINT + 0xbff8, 8));
    for (int i = 1; i < PLIC_SRC; i++) fprintf(f, "plic.priority%d %" PRIx64 "\n", i, mem_read(PLIC + 4 * i, 4));
    for (int c = 0; c < 2; c++) {  /* context 0: M-mode, 1: S-mode */
        for (int w = 0; w < PLIC_SRC / 32; w++)
            fprintf(f, "plic.enable%d.%d %" PRIx64 "\n", c, w, mem_read(PLIC + 0x2000 + 0x80 * c + 4 * w, 4));
        fprintf(f, "plic.threshold%d %" PRIx64 "\n", c, mem_read(PLIC + 0x200000 + 0x1000 * c, 4));
    }
    /* 16550: IER, LCR, MCR, SCR read back without side effects; the divisor through LCR.DLAB, then LCR as it was */
    uint8_t lcr = mem_read(UART + 3, 1);
    fprintf(f, "uart.ier %" PRIx64 "\nuart.lcr %x\nuart.mcr %" PRIx64 "\nuart.scr %" PRIx64 "\n",
            mem_read(UART + 1, 1), lcr, mem_read(UART + 4, 1), mem_read(UART + 7, 1));
    mem_write1(UART + 3, lcr | 0x80);
    fprintf(f, "uart.dll %" PRIx64 "\nuart.dlm %" PRIx64 "\n", mem_read(UART, 1), mem_read(UART + 1, 1));
    mem_write1(UART + 3, lcr);
}

static void dump_ram(const char *name)
{
    FILE *f = fopen(name, "wb");
    const size_t chunk = 1 << 20;
    GByteArray *buf = g_byte_array_new();
    if (!f) { perror(name); _exit(1); }
    for (uint64_t off = 0; off < ram_mib << 20; off += chunk) {
        if (qemu_plugin_read_memory_hwaddr(RAM_BASE + off, buf, chunk) != QEMU_PLUGIN_HWADDR_OPERATION_OK) {
            fprintf(stderr, "roickpt: RAM read at 0x%" PRIx64 " failed\n", (uint64_t)(RAM_BASE + off));
            _exit(1);
        }
        for (size_t i = 0; i < chunk; i += 8)  /* the testbench $freads 64-bit words, most significant byte first */
            for (int j = 0; j < 4; j++) { uint8_t t = buf->data[i + j]; buf->data[i + j] = buf->data[i + 7 - j]; buf->data[i + 7 - j] = t; }
        fwrite(buf->data, 1, chunk, f);
    }
    g_byte_array_free(buf, TRUE);
    fclose(f);
}

static void checkpoint(uint64_t k)
{
    char *dir = g_strdup_printf("%s/%" PRIu64, outdir, k), *name;
    if (mkdir(dir, 0777) && errno != EEXIST) { perror(dir); _exit(1); }

    name = g_strdup_printf("%s/state.txt", dir);
    FILE *f = fopen(name, "w");
    if (!f) { perror(name); _exit(1); }
    for (guint i = 0; i < regs->len; i++) {
        Reg *r = &g_array_index(regs, Reg, i);
        fprintf(f, "%s %" PRIx64 "\n", r->name, reg_value(r->h, NULL));
    }
    dump_devices(f);
    fclose(f);
    g_free(name);

    name = g_strdup_printf("%s/ram.bin", dir);
    dump_ram(name);
    g_free(name);

    name = g_strdup_printf("%s/info.txt", dir);
    f = fopen(name, "w");
    fprintf(f, "interval_number %" PRIu64 "\ninterval %" PRIu64 "\nwarmup %" PRIu64 "\n"
            "instructions_since_boot %" PRIu64 "\ninstructions_since_roi_start %" PRIu64 "\n"
            "interval_starts_after %" PRId64 "\n",
            k, interval, warmup, total, roi_insns, (int64_t)(k * interval - roi_insns));
    fclose(f);
    g_free(name);
    fprintf(stderr, "roickpt: checkpoint %" PRIu64 " at instruction %" PRIu64 " (pc %" PRIx64 ", priv %" PRIu64 ")\n",
            k, total, reg_value(pc_reg, NULL), reg_value(priv_reg, NULL));
    if (notimer) {  /* no timer interrupt to wait for: stimecmp as far as it goes (the kernel sets it before it enables one) */
        FILE *sf = fopen(g_strdup_printf("%s/state.txt", dir), "a");
        fputs("stimecmp ffffffffffffffff\n", sf);
        fclose(sf);
    } else
        g_ptr_array_add(pending, g_strdup_printf("%s/state.txt", dir));
    g_free(dir);
}

static void maybe_exit(void)
{
    if (next_target < ntargets || pending->len || (trace_n && traced < trace_n)) return;
    if (tf) fclose(tf);
    fputs("roickpt: done\n", stderr); fflush(stderr); _exit(0);
}

/* in the first block of an interrupt handler: a supervisor timer interrupt gives the stimecmp of the pending checkpoints */
static void after_interrupt(void)
{
    irq_seen = 0;
    if (!pending->len || reg_value(scause_reg, NULL) != 0x8000000000000005ull) return;
    uint64_t mtime = mem_read(CLINT + 0xbff8, 8);
    for (guint i = 0; i < pending->len; i++) {
        FILE *f = fopen(g_ptr_array_index(pending, i), "a");
        if (!f) { perror(g_ptr_array_index(pending, i)); _exit(1); }
        fprintf(f, "stimecmp %" PRIx64 "\n", mtime);
        fclose(f);
    }
    fprintf(stderr, "roickpt: stimecmp %" PRIx64 " at instruction %" PRIu64 " for %u checkpoint(s)\n", mtime, total, pending->len);
    g_ptr_array_set_size(pending, 0);
    maybe_exit();
}

static void tb_exec(unsigned int vcpu, void *udata)
{
    uint64_t n = (uintptr_t)udata;
    if (irq_seen) after_interrupt();
    if (roi_end_total && total > roi_end_total + 100000000) {  /* no timer interrupt within 100 M instructions */
        fprintf(stderr, "roickpt: no timer interrupt after the region; %u checkpoint(s) without stimecmp\n", pending->len);
        fputs("roickpt: done\n", stderr); fflush(stderr); _exit(0);
    }
    if (roi && next_target < ntargets) {
        uint64_t k = targets[next_target];
        uint64_t at = k * interval > warmup ? k * interval - warmup : 0;
        if (roi_insns >= at && reg_value(priv_reg, NULL) != 3) {  /* never inside OpenSBI */
            checkpoint(k);
            if (++next_target == ntargets) {
                fputs("roickpt: all checkpoints taken\n", stderr); fflush(stderr);
                if (trace_n) tracing = 1;  /* the instruction callbacks of this block write it, from its first instruction */
                maybe_exit();              /* notimer=1 without a trace: nothing left to wait for */
            }
        }
    }
    total += n;
    if (roi) roi_insns += n;
}

static void trace_insn(unsigned int vcpu, void *udata)
{
    if (!tracing) return;
    fprintf(tf, "%" PRIx64 "\n", (uint64_t)(uintptr_t)udata);
    if (++traced == trace_n) { tracing = 0; fputs("roickpt: trace done\n", stderr); fflush(stderr); maybe_exit(); }
}

static void discon(qemu_plugin_id_t id, unsigned int vcpu, enum qemu_plugin_discon_type type, uint64_t from, uint64_t to)
{
    if (tracing) fprintf(tf, "T %c %" PRIx64 "\n", type == QEMU_PLUGIN_DISCON_INTERRUPT ? 'I' : 'E', from);
    if (type == QEMU_PLUGIN_DISCON_INTERRUPT) { irq_seen = 1; if (roi) roi_interrupts++; }
}

static void marker(unsigned int vcpu, void *udata)
{
    if ((uintptr_t)udata == ROI_START) {
        roi = 1;
        roi_start_insn = total;
        if (notimer) timer_off();
        fprintf(stderr, "roickpt: ROI start at instruction %" PRIu64 "\n", total);
    } else if (roi && next_target == ntargets) {  /* all taken: run on to the next timer interrupt (stimecmp) */
        roi = 0;
        roi_end_total = total;
        fprintf(stderr, "roickpt: ROI ended, waiting for the timer interrupt of %u checkpoint(s)\n", pending->len);
    } else if (roi) {
        fprintf(stderr, "roickpt: ROI ended with %zu of %zu checkpoints\n", next_target, ntargets);
        fflush(stderr);
        _exit(1);
    }
}

static void tb_trans(qemu_plugin_id_t id, struct qemu_plugin_tb *tb)
{
    size_t n = qemu_plugin_tb_n_insns(tb);
    qemu_plugin_register_vcpu_tb_exec_cb(tb, tb_exec, QEMU_PLUGIN_CB_R_REGS, (void *)(uintptr_t)n);
    for (size_t i = 0; i < n; i++) {
        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);
        uint32_t word = 0;
        if (qemu_plugin_insn_size(insn) == 4) qemu_plugin_insn_data(insn, &word, 4);
        if (trace_n)
            qemu_plugin_register_vcpu_insn_exec_cb(insn, trace_insn, QEMU_PLUGIN_CB_NO_REGS,
                                                   (void *)(uintptr_t)qemu_plugin_insn_vaddr(insn));
        if (word == ROI_START || word == ROI_END)
            qemu_plugin_register_vcpu_insn_exec_cb(insn, marker, notimer ? QEMU_PLUGIN_CB_RW_REGS : QEMU_PLUGIN_CB_NO_REGS,
                                                   (void *)(uintptr_t)word);
    }
}

static void vcpu_init(qemu_plugin_id_t id, unsigned int vcpu)
{
    GArray *descs = qemu_plugin_get_registers();
    regs = g_array_new(FALSE, FALSE, sizeof(Reg));
    for (guint i = 0; i < descs->len; i++) {
        qemu_plugin_reg_descriptor *d = &g_array_index(descs, qemu_plugin_reg_descriptor, i);
        Reg r = { g_strdup(d->name), d->handle };
        g_array_append_val(regs, r);
        if (!strcmp(d->name, "pc")) pc_reg = d->handle;
        if (!strcmp(d->name, "priv")) priv_reg = d->handle;
        if (!strcmp(d->name, "scause")) scause_reg = d->handle;
        if (!strcmp(d->name, "mie")) mie_reg = d->handle;
    }
    g_array_free(descs, TRUE);
    if (!pc_reg || !priv_reg || !scause_reg) { fputs("roickpt: no pc, priv or scause register\n", stderr); _exit(1); }
}

static int cmp_u64(const void *a, const void *b)
{
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id, const qemu_info_t *info, int argc, char **argv)
{
    for (int i = 0; i < argc; i++) {
        if (!strncmp(argv[i], "interval=", 9)) interval = strtoull(argv[i] + 9, NULL, 10);
        else if (!strncmp(argv[i], "warmup=", 7)) warmup = strtoull(argv[i] + 7, NULL, 10);
        else if (!strncmp(argv[i], "ram=", 4)) ram_mib = strtoull(argv[i] + 4, NULL, 10);
        else if (!strncmp(argv[i], "points=", 7)) points = g_strdup(argv[i] + 7);
        else if (!strncmp(argv[i], "outdir=", 7)) outdir = g_strdup(argv[i] + 7);
        else if (!strncmp(argv[i], "notimer=", 8)) notimer = atoi(argv[i] + 8);
        else if (!strncmp(argv[i], "trace=", 6)) trace_n = strtoull(argv[i] + 6, NULL, 10);
        else if (!strncmp(argv[i], "tracefile=", 10)) tracefile = g_strdup(argv[i] + 10);
        else { fprintf(stderr, "roickpt: unknown option %s\n", argv[i]); return -1; }
    }
    FILE *f = points ? fopen(points, "r") : NULL;
    if (!f || !outdir) { fputs("roickpt: points=<SimPoint .simpoints file> and outdir=<dir> needed\n", stderr); return -1; }
    uint64_t k, cluster;
    while (fscanf(f, "%" SCNu64 " %" SCNu64, &k, &cluster) == 2) {
        targets = g_renew(uint64_t, targets, ntargets + 1);
        targets[ntargets++] = k;
    }
    fclose(f);
    if (!ntargets) { fprintf(stderr, "roickpt: no points in %s\n", points); return -1; }
    qsort(targets, ntargets, sizeof *targets, cmp_u64);
    if (mkdir(outdir, 0777) && errno != EEXIST) { perror(outdir); return -1; }
    pending = g_ptr_array_new_with_free_func(g_free);
    qemu_plugin_register_vcpu_discon_cb(id, QEMU_PLUGIN_DISCON_INTERRUPT | QEMU_PLUGIN_DISCON_EXCEPTION, discon);
    if (trace_n) {
        if (!tracefile || !(tf = fopen(tracefile, "w"))) { fputs("roickpt: trace=<n> needs a writable tracefile=<file>\n", stderr); return -1; }
    }
    qemu_plugin_register_vcpu_init_cb(id, vcpu_init);
    qemu_plugin_register_vcpu_tb_trans_cb(id, tb_trans);
    return 0;
}
