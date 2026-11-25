// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
/*
 * roibbv: basic block vectors of a region of interest, for SimPoint, in full-system QEMU (one hart).
 * The region starts and ends at two HINT instructions (slti x0, x0, 0x7a1 / 0x7a2) that roi-start and roi-end
 * execute in the guest; the plugin prints the instruction count since boot at each, writes one vector line
 * per <interval> instructions of the region ("T:<block>:<instructions> ..."), and stops QEMU at the end.
 *   qemu-system-riscv64 ... -icount shift=0,sleep=off -plugin ./libroibbv.so,interval=10000000,outfile=app.bb
 */
#include <glib.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <qemu-plugin.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

#define ROI_START 0x7a102013u  /* slti x0, x0, 0x7a1 */
#define ROI_END   0x7a202013u  /* slti x0, x0, 0x7a2 */

typedef struct { uint64_t pc; uint32_t id; uint32_t ninsns; uint64_t count; } Block;

/* A block is its start address and length: the same virtual address can start blocks of other lengths (another
 * process, or QEMU translating a shorter block there), and counting them with the first length found is wrong. */
static guint block_hash(gconstpointer k) { const Block *b = k; return g_int64_hash(&b->pc) ^ b->ninsns; }
static gboolean block_equal(gconstpointer a, gconstpointer b)
{
    const Block *x = a, *y = b;
    return x->pc == y->pc && x->ninsns == y->ninsns;
}

static GHashTable *blocks;      /* (pc, ninsns) -> Block */
static GPtrArray *order;        /* blocks by id */
static uint64_t total;          /* instructions since boot (block granularity) */
static uint64_t in_interval, interval = 10000000, roi_start_insn, roi_insns;
static int roi;
static FILE *out;
static char *outname;

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

static void dump_interval(void)
{
    fputs("T", out);
    for (guint i = 0; i < order->len; i++) {
        Block *b = g_ptr_array_index(order, i);
        if (b->count) {
            fprintf(out, ":%u:%" PRIu64 " ", b->id, b->count);
            b->count = 0;
        }
    }
    fputs("\n", out);
    in_interval = 0;
}

static void tb_exec(unsigned int vcpu, void *udata)
{
    Block *b = udata;
    total += b->ninsns;
    if (!roi) return;
    b->count += b->ninsns;
    roi_insns += b->ninsns;
    in_interval += b->ninsns;
    if (in_interval >= interval) dump_interval();
}

static void marker(unsigned int vcpu, void *udata)
{
    if ((uintptr_t)udata == ROI_START) {
        roi = 1;
        roi_start_insn = total;
        if (notimer) timer_off();
        fprintf(stderr, "roibbv: ROI start at instruction %" PRIu64 "\n", total);
    } else if (roi) {
        if (in_interval >= interval / 2) dump_interval();
        fclose(out);
        fprintf(stderr, "roibbv: %" PRIu64 " interrupts in the ROI%s\n", roi_interrupts, notimer ? " (timer off)" : "");
        fprintf(stderr, "roibbv: ROI end at instruction %" PRIu64 ", %" PRIu64 " in the ROI, interval %" PRIu64 "\n",
                total, roi_insns, interval);
        fflush(stderr);
        _exit(0);  /* stop QEMU: the guest has no way to power the virt machine off with Wally's device tree */
    }
}

static void tb_trans(qemu_plugin_id_t id, struct qemu_plugin_tb *tb)
{
    Block key = { .pc = qemu_plugin_tb_vaddr(tb), .ninsns = qemu_plugin_tb_n_insns(tb) };
    Block *b = g_hash_table_lookup(blocks, &key);
    if (!b) {
        b = g_new0(Block, 1);
        *b = key;
        b->id = order->len + 1;
        g_hash_table_insert(blocks, b, b);
        g_ptr_array_add(order, b);
    }
    qemu_plugin_register_vcpu_tb_exec_cb(tb, tb_exec, QEMU_PLUGIN_CB_NO_REGS, b);
    for (size_t i = 0; i < qemu_plugin_tb_n_insns(tb); i++) {
        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);
        uint32_t word = 0;
        if (qemu_plugin_insn_size(insn) == 4) qemu_plugin_insn_data(insn, &word, 4);
        if (word == ROI_START || word == ROI_END)
            qemu_plugin_register_vcpu_insn_exec_cb(insn, marker, notimer ? QEMU_PLUGIN_CB_RW_REGS : QEMU_PLUGIN_CB_NO_REGS,
                                                   (void *)(uintptr_t)word);
    }
}

static void discon(qemu_plugin_id_t id, unsigned int vcpu, enum qemu_plugin_discon_type type, uint64_t from, uint64_t to)
{
    if (roi) roi_interrupts++;
}

static void vcpu_init(qemu_plugin_id_t id, unsigned int vcpu)
{
    GArray *descs = qemu_plugin_get_registers();
    for (guint i = 0; i < descs->len; i++) {
        qemu_plugin_reg_descriptor *d = &g_array_index(descs, qemu_plugin_reg_descriptor, i);
        if (!strcmp(d->name, "mie")) mie_reg = d->handle;
    }
    g_array_free(descs, TRUE);
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id, const qemu_info_t *info, int argc, char **argv)
{
    for (int i = 0; i < argc; i++) {
        if (!strncmp(argv[i], "interval=", 9)) interval = strtoull(argv[i] + 9, NULL, 10);
        else if (!strncmp(argv[i], "outfile=", 8)) outname = g_strdup(argv[i] + 8);
        else if (!strncmp(argv[i], "notimer=", 8)) notimer = atoi(argv[i] + 8);
        else { fprintf(stderr, "roibbv: unknown option %s\n", argv[i]); return -1; }
    }
    if (!outname || !(out = fopen(outname, "w"))) { fputs("roibbv: outfile=<file> needed\n", stderr); return -1; }
    blocks = g_hash_table_new(block_hash, block_equal);
    order = g_ptr_array_new();
    qemu_plugin_register_vcpu_init_cb(id, vcpu_init);
    qemu_plugin_register_vcpu_discon_cb(id, QEMU_PLUGIN_DISCON_INTERRUPT, discon);
    qemu_plugin_register_vcpu_tb_trans_cb(id, tb_trans);
    return 0;
}
