/*
 * memtrace — a QEMU TCG plugin that records every LINEAR-MEMORY access the lowered falcon
 * cascade makes, with the PC that made it.
 *
 * WHY THIS EXISTS. synth#1436: the synth-lowered `ekf#estimate` disagrees with wasmtime on four
 * of fourteen state words, bit-identically on Renode, QEMU and the real RT1176 (AFD-125/132).
 * Every external variable has been eliminated — loom, the emulator, the compiler version, the
 * argument marshalling, the return ABI. synth's first disassembly pass then narrowed it to the
 * INTEGER path and named the measurement that would decide it:
 *
 *     "the QEMU run, watching which addresses the rotation's quaternion loads actually resolve
 *      to against the ones the attitude update stores. That decides it without reconstructing
 *      the dataflow."
 *
 * It cannot be read statically, and synth said why: all 236 `r11` accesses are register-offset,
 * none constant-offset, so the addresses only exist at run time. A static reader cannot settle
 * "the update writes one field, the rotation reads another". A run can.
 *
 * WHY A PLUGIN AND NOT GDB WATCHPOINTS. A watchpoint needs the address in advance, which is the
 * thing being looked for; and the Cortex-M7 has four. This records the whole access stream and
 * lets the question be asked afterwards, which also means one run answers questions not yet
 * thought of.
 *
 * WHAT IT DOES NOT DO: it does not know what a quaternion is, which function it is in, or what
 * `tick` means. It emits (pc, address, size, r/w) and nothing else. Attribution to symbols and
 * to ticks is done afterwards, from the ELF, by analyse.py — deliberately, so the thing doing
 * the measuring cannot be the thing deciding what the measurement means.
 *
 * ARGS:  out=<path>   where to write the trace (default stderr via qemu_plugin_outs)
 *        lo=<hex>     low bound of the address window, inclusive  (default 0x20000000)
 *        hi=<hex>     high bound, exclusive                       (default 0x20010000)
 *        pclo=<hex>   only record accesses made by a PC >= pclo   (default 0)
 *        pchi=<hex>   ...and < pchi                               (default ~0)
 *        max=<n>      stop recording after n events (0 = no limit, default 20000000)
 *
 * OUTPUT: '<seq> <pc> <addr> <bytes> <R|W> <value>', all hex except seq and bytes.
 *
 * The window matters: the image's LINMEM is 0x20000000..0x20010000 and its stack is at
 * 0x20040000. synth measured that every f32 access in the three functions goes through `sp` and
 * ZERO through `r11`, so the f32 frame traffic is in the stack region and the persistent state —
 * the quaternion — is the integer traffic in the LINMEM window. Narrowing to that window is
 * therefore not a convenience; it is what separates the two paths.
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <glib.h>
#include <qemu-plugin.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

static FILE *out;
static uint64_t lo = 0x20000000, hi = 0x20010000;
static uint64_t pclo = 0, pchi = UINT64_MAX;
static uint64_t maxev = 20000000;
static uint64_t n_emitted, n_seen, n_dropped;

static void vcpu_mem(unsigned int vcpu_index, qemu_plugin_meminfo_t info,
                     uint64_t vaddr, void *udata)
{
    uint64_t pc = (uint64_t)(uintptr_t)udata;
    n_seen++;
    if (vaddr < lo || vaddr >= hi) {
        return;
    }
    if (pc < pclo || pc >= pchi) {
        return;
    }
    if (maxev && n_emitted >= maxev) {
        n_dropped++;
        return;
    }
    /* One line per access. Fixed fields, no quoting, so the reader cannot misparse it:
     *   <seq> <pc> <addr> <bytes> <R|W> <value-hex>
     * The sequence number is what makes ORDER recoverable, which is the entire question here:
     * whether a load of an address happens before or after the store to it within one tick.
     *
     * THE VALUE IS WHAT MAKES THE QUATERNION IDENTIFIABLE WITHOUT GUESSING. The addresses are
     * computed at run time and there is no symbol for them, so "which address holds the
     * quaternion" would otherwise be an inference from the access pattern. With values it is a
     * LOOKUP: the parked state words give the quaternion bit patterns the run produced, and the
     * slot is whichever address those words were stored to. Objective, and checkable by anyone
     * re-running this. */
    qemu_plugin_mem_value v = qemu_plugin_mem_get_value(info);
    uint64_t raw = 0;
    switch (v.type) {
    case QEMU_PLUGIN_MEM_VALUE_U8:   raw = v.data.u8;  break;
    case QEMU_PLUGIN_MEM_VALUE_U16:  raw = v.data.u16; break;
    case QEMU_PLUGIN_MEM_VALUE_U32:  raw = v.data.u32; break;
    case QEMU_PLUGIN_MEM_VALUE_U64:  raw = v.data.u64; break;
    case QEMU_PLUGIN_MEM_VALUE_U128: raw = v.data.u128.low; break;
    default:                         raw = 0; break;
    }
    fprintf(out, "%" PRIu64 " %08" PRIx64 " %08" PRIx64 " %u %c %" PRIx64 "\n",
            n_emitted, pc, vaddr,
            1u << qemu_plugin_mem_size_shift(info),
            qemu_plugin_mem_is_store(info) ? 'W' : 'R', raw);
    n_emitted++;
}

/* Plugin API v7: the translate callback takes (tb, userdata) — no plugin id. */
static void tb_trans(struct qemu_plugin_tb *tb, void *userdata)
{
    size_t n = qemu_plugin_tb_n_insns(tb);
    for (size_t i = 0; i < n; i++) {
        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);
        uint64_t pc = qemu_plugin_insn_vaddr(insn);
        qemu_plugin_register_vcpu_mem_cb(insn, vcpu_mem, QEMU_PLUGIN_CB_NO_REGS,
                                         QEMU_PLUGIN_MEM_RW, (void *)(uintptr_t)pc);
    }
}

static void at_exit(void *p)
{
    /* THE TRAILER IS NOT DECORATION. A trace that recorded nothing and a trace whose tracer was
     * never wired up look identical downstream — both are an empty file. `seen` counts accesses
     * the callback was invoked for BEFORE any filtering, so a nonzero `seen` with zero `emitted`
     * says "the tracer works and the window is wrong", which is a different finding from "the
     * tracer is blind". analyse.py REFUSES a trace whose trailer is missing or whose seen is 0. */
    fprintf(out, "# trailer emitted=%" PRIu64 " seen=%" PRIu64 " dropped=%" PRIu64
                 " window=%08" PRIx64 "-%08" PRIx64 " pc=%08" PRIx64 "-%08" PRIx64 "\n",
            n_emitted, n_seen, n_dropped, lo, hi, pclo, pchi);
    if (out != stderr) {
        fclose(out);
    }
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id, const qemu_info_t *info,
                                           int argc, char **argv)
{
    const char *path = NULL;
    for (int i = 0; i < argc; i++) {
        char *o = argv[i];
        if (g_str_has_prefix(o, "out=")) {
            path = o + 4;
        } else if (g_str_has_prefix(o, "lo=")) {
            lo = g_ascii_strtoull(o + 3, NULL, 16);
        } else if (g_str_has_prefix(o, "hi=")) {
            hi = g_ascii_strtoull(o + 3, NULL, 16);
        } else if (g_str_has_prefix(o, "pclo=")) {
            pclo = g_ascii_strtoull(o + 5, NULL, 16);
        } else if (g_str_has_prefix(o, "pchi=")) {
            pchi = g_ascii_strtoull(o + 5, NULL, 16);
        } else if (g_str_has_prefix(o, "max=")) {
            maxev = g_ascii_strtoull(o + 4, NULL, 10);
        } else {
            fprintf(stderr, "memtrace: unknown argument '%s'\n", o);
            return -1;   /* REFUSE rather than ignore: a typo'd window would silently produce an
                          * empty trace, which reads as "no accesses" — a vacuous answer. */
        }
    }
    out = path ? fopen(path, "w") : stderr;
    if (!out) {
        fprintf(stderr, "memtrace: cannot open output\n");
        return -1;
    }
    fprintf(out, "# memtrace window=%08" PRIx64 "-%08" PRIx64 " pc=%08" PRIx64 "-%08" PRIx64 "\n",
            lo, hi, pclo, pchi);
    qemu_plugin_register_vcpu_tb_trans_cb(id, tb_trans, NULL);
    qemu_plugin_register_atexit_cb(id, at_exit, NULL);
    return 0;
}
