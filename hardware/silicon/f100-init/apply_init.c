/* THE MISSING HALF. extract_init.py emits TABLES; nothing ever consumed them.
 * `it links` is not `it works` — until this loop runs on a target, the two
 * promises AFD-046 made to synth are undischarged.
 *
 * Generic over the emitted tables on purpose: this is the embedder obligation
 * for ANY --relocatable image, not a fixture for this probe.
 *
 * Freestanding: no libc headers (homebrew's arm-none-eabi-gcc ships none).
 */
typedef unsigned char jess_u8;
typedef unsigned int  jess_u32;
typedef unsigned long jess_usize;
typedef struct { jess_u32 dst; jess_u32 off; jess_u32 len; } jess_seg_t;

extern const jess_u8    jess_wasm_data_blob[];
extern const jess_seg_t jess_wasm_data_segs[];
extern const jess_usize jess_wasm_data_seg_count;
extern const jess_u32   jess_wasm_global_init[];
extern const jess_usize jess_wasm_global_count;

/* linmem = the R11 base the caller will install; globals = the R9 table. */
void jess_wasm_apply_init(jess_u8 *linmem, jess_u32 *globals)
{
    for (jess_usize i = 0; i < jess_wasm_data_seg_count; i++) {
        const jess_seg_t *s = &jess_wasm_data_segs[i];
        for (jess_u32 b = 0; b < s->len; b++)
            linmem[s->dst + b] = jess_wasm_data_blob[s->off + b];
    }
    for (jess_usize g = 0; g < jess_wasm_global_count; g++)
        globals[g] = jess_wasm_global_init[g];
}
