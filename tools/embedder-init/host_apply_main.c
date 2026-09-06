/* EXECUTE the apply loop on the host so a NO-OP loop is caught.
 *
 * The link-clean CI step verifies that apply_init.c LINKS against the cascade's
 * tables. A clean-room audit showed that step still passes when the body of
 * jess_wasm_apply_init is gutted to `return;` — it gates linkability, not
 * consumption. This runs the real loop over the real tables and dumps what it
 * produced, so the result can be compared against wasmtime's own instantiated
 * memory by an independent path.
 */
typedef unsigned char jess_u8;
typedef unsigned int  jess_u32;
typedef unsigned long jess_usize;
typedef struct { jess_u32 dst; jess_u32 off; jess_u32 len; } jess_seg_t;

extern const jess_seg_t jess_wasm_data_segs[];
extern const jess_usize jess_wasm_data_seg_count;
extern const jess_usize jess_wasm_global_count;
void jess_wasm_apply_init(jess_u8 *linmem, jess_u32 *globals);

#include <stdio.h>
#include <stdlib.h>

#define POISON 0xEF

int main(int argc, char **argv)
{
    if (argc != 3) { fprintf(stderr, "usage: %s <mem.bin> <globals.bin>\n", argv[0]); return 2; }

    jess_u32 top = 0;
    for (jess_usize i = 0; i < jess_wasm_data_seg_count; i++) {
        jess_u32 end = jess_wasm_data_segs[i].dst + jess_wasm_data_segs[i].len;
        if (end > top) top = end;
    }
    jess_usize size = (jess_usize)top + 4096;          /* headroom stays POISON */
    jess_u8 *mem = malloc(size);
    jess_u32 *globals = calloc(jess_wasm_global_count ? jess_wasm_global_count : 1, 4);
    if (!mem || !globals) { fprintf(stderr, "alloc failed\n"); return 2; }
    for (jess_usize i = 0; i < size; i++) mem[i] = POISON;
    for (jess_usize i = 0; i < jess_wasm_global_count; i++) globals[i] = 0xDEADBEEFu;

    jess_wasm_apply_init(mem, globals);

    FILE *f = fopen(argv[1], "wb"); if (!f) return 2;
    fwrite(mem, 1, size, f); fclose(f);
    f = fopen(argv[2], "wb"); if (!f) return 2;
    fwrite(globals, 4, jess_wasm_global_count, f); fclose(f);
    printf("applied %lu segment(s), %lu global(s) into %lu bytes\n",
           (unsigned long)jess_wasm_data_seg_count,
           (unsigned long)jess_wasm_global_count, (unsigned long)size);
    return 0;
}
