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
static char *outdir, *points;

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
    g_free(dir);
}

static void tb_exec(unsigned int vcpu, void *udata)
{
    uint64_t n = (uintptr_t)udata;
    if (roi && next_target < ntargets) {
        uint64_t k = targets[next_target];
        uint64_t at = k * interval > warmup ? k * interval - warmup : 0;
        if (roi_insns >= at && reg_value(priv_reg, NULL) != 3) {  /* never inside OpenSBI */
            checkpoint(k);
            if (++next_target == ntargets) { fputs("roickpt: done\n", stderr); fflush(stderr); _exit(0); }
        }
    }
    total += n;
    if (roi) roi_insns += n;
}

static void marker(unsigned int vcpu, void *udata)
{
    if ((uintptr_t)udata == ROI_START) {
        roi = 1;
        roi_start_insn = total;
        fprintf(stderr, "roickpt: ROI start at instruction %" PRIu64 "\n", total);
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
        if (word == ROI_START || word == ROI_END)
            qemu_plugin_register_vcpu_insn_exec_cb(insn, marker, QEMU_PLUGIN_CB_NO_REGS, (void *)(uintptr_t)word);
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
    }
    g_array_free(descs, TRUE);
    if (!pc_reg || !priv_reg) { fputs("roickpt: no pc or priv register\n", stderr); _exit(1); }
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
    qemu_plugin_register_vcpu_init_cb(id, vcpu_init);
    qemu_plugin_register_vcpu_tb_trans_cb(id, tb_trans);
    return 0;
}
