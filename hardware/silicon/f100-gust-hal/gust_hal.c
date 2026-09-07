/* jess's gust:hal for Cortex-M — the REAL one, not app/gust-hal-stub.
 *
 * This is the whole native seam the wasm side names: two volatile accesses.
 * `volatile` is load-bearing — without it -O2 folds the read-back of a value the
 * compiler just "wrote" and the probe would report success without touching the bus.
 *
 * MUST be compiled with -ffixed-r9 -ffixed-r10 -ffixed-r11: these run BETWEEN
 * synth-lowered calls, which hold the linear-memory base, size and globals table in
 * exactly those registers. synth's verify-embedder checks the emitted code rather
 * than trusting the flags (a flag that silently stopped applying looks like one that
 * works), and build.sh gates on it.
 */
typedef unsigned int u32;

u32 read32(u32 addr)
{
    return *(volatile u32 *)addr;
}

void write32(u32 addr, u32 val)
{
    *(volatile u32 *)addr = val;
}
