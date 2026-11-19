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

static GHashTable *blocks;      /* pc -> Block */
static GPtrArray *order;        /* blocks by id */
static uint64_t total;          /* instructions since boot (block granularity) */
static uint64_t in_interval, interval = 10000000, roi_start_insn, roi_insns;
static int roi;
static FILE *out;
static char *outname;

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
        fprintf(stderr, "roibbv: ROI start at instruction %" PRIu64 "\n", total);
    } else if (roi) {
        if (in_interval >= interval / 2) dump_interval();
        fclose(out);
        fprintf(stderr, "roibbv: ROI end at instruction %" PRIu64 ", %" PRIu64 " in the ROI, interval %" PRIu64 "\n",
                total, roi_insns, interval);
        fflush(stderr);
        _exit(0);  /* stop QEMU: the guest has no way to power the virt machine off with Wally's device tree */
    }
}

static void tb_trans(qemu_plugin_id_t id, struct qemu_plugin_tb *tb)
{
    uint64_t pc = qemu_plugin_tb_vaddr(tb);
    Block *b = g_hash_table_lookup(blocks, &pc);
    if (!b) {
        b = g_new0(Block, 1);
        b->pc = pc;
        b->id = order->len + 1;
        b->ninsns = qemu_plugin_tb_n_insns(tb);
        g_hash_table_insert(blocks, &b->pc, b);
        g_ptr_array_add(order, b);
    }
    qemu_plugin_register_vcpu_tb_exec_cb(tb, tb_exec, QEMU_PLUGIN_CB_NO_REGS, b);
    for (size_t i = 0; i < qemu_plugin_tb_n_insns(tb); i++) {
        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);
        uint32_t word = 0;
        if (qemu_plugin_insn_size(insn) == 4) qemu_plugin_insn_data(insn, &word, 4);
        if (word == ROI_START || word == ROI_END)
            qemu_plugin_register_vcpu_insn_exec_cb(insn, marker, QEMU_PLUGIN_CB_NO_REGS, (void *)(uintptr_t)word);
    }
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id, const qemu_info_t *info, int argc, char **argv)
{
    for (int i = 0; i < argc; i++) {
        if (!strncmp(argv[i], "interval=", 9)) interval = strtoull(argv[i] + 9, NULL, 10);
        else if (!strncmp(argv[i], "outfile=", 8)) outname = g_strdup(argv[i] + 8);
        else { fprintf(stderr, "roibbv: unknown option %s\n", argv[i]); return -1; }
    }
    if (!outname || !(out = fopen(outname, "w"))) { fputs("roibbv: outfile=<file> needed\n", stderr); return -1; }
    blocks = g_hash_table_new(g_int64_hash, g_int64_equal);
    order = g_ptr_array_new();
    qemu_plugin_register_vcpu_tb_trans_cb(id, tb_trans);
    return 0;
}
