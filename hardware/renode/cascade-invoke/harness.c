/* TEST-PIX-032 harness — apply the embedder obligations, then invoke a cascade stage.
 *
 * FREESTANDING: no libc headers (the cross toolchain may ship none — AFD-051).
 */
typedef unsigned char jess_u8;
typedef unsigned int  jess_u32;
typedef unsigned long jess_usize;

/* Emitted by tools/embedder-init/extract_init.py FROM THE SAME MODULE this links
 * against — binding enforced by run.sh's LOWER= path (AFD-053 S1). */
extern const jess_u8   jess_wasm_data_blob[];
typedef struct { jess_u32 dst; jess_u32 off; jess_u32 len; } jess_seg_t;
extern const jess_seg_t jess_wasm_data_segs[];
extern const jess_usize jess_wasm_data_seg_count;
extern const jess_u32   jess_wasm_global_init[];
extern const jess_usize jess_wasm_global_count;

#define LINMEM   ((volatile jess_u8  *)0x20000000u)
#define GLOBALS  ((volatile jess_u32 *)0x20010100u)
#define ARGOFF   0x0000E000u
/* NOT above the static data: __data_end is 0x45A1 and a data segment spans [0x290,0x22B1),
 * so this band overlaps ~7 KiB of applied segment data. Painting is safe only because those
 * bytes are zero and never read — build.sh asserts that against the actual module rather
 * than trusting this comment. (Clean-room finding; the previous comment was wrong.) */
#define PAINT_LO 0x00000400u
#define PAINT_HI 0x00002000u   /* the shadow-stack pointer's initial value (global 0) */

/* The canonical ABI of the export, from the WIT and the lowered signature:
 *     rate@0.7.0#tick : (param i32) -> (result i32)
 * The symbol carries ':' '@' and '#', so it is reached via an asm label rather than
 * a C identifier. */
/* The export symbol contains ':' '@' and '#'. '@' begins a comment in ARM assembly, so an
 * __asm__ label truncates it mid-name — the assembler reports "garbage following
 * instruction". The object is therefore renamed with
 *   objcopy --redefine-sym 'pulseengine:falcon-cascade/rate@0.7.0#tick=jess_rate_tick'
 * which sidesteps assembler quoting entirely. build.sh does this and ASSERTS the rename
 * landed, so a silent objcopy no-op cannot leave an unresolved reference. */
extern int jess_rate_tick(int arg);

/* mixer@0.7.0#mix : (param f32 f32 f32 f32) -> (result i32)
 *
 * NOTE THE ASYMMETRY, which is the point of this stage of the harness: rate#tick takes a
 * POINTER (18 scalars exceeds the Canonical ABI flattening limit) while mixer#mix takes
 * FOUR FLATTENED f32s (4 does not). Assuming a uniform pointer-in convention here passes
 * garbage silently rather than erroring — jess recorded that asymmetry months ago in
 * cascade_ref.py and it is exactly what meld#393's bridge is stuck on.
 * Renamed by objcopy for the same '@'-begins-a-comment reason as rate. */
extern int jess_mixer_mix(float tx, float ty, float tz, float thrust);

/* ekf@<ver>#estimate : (param f32 f32 f32 f32 f32 f32) -> (result i32)
 *
 * THE THIRD CALLING SHAPE, and the reason this rung exists. The cascade uses all three:
 *     rate#tick      18 flat params > 16  -> a POINTER in, pointer out
 *     mixer#mix       4 flat params       -> FOUR FLATTENED f32, pointer out
 *     ekf#estimate    6 flat params       -> SIX FLATTENED f32, pointer out
 * ekf is NOT a pointer even though its argument is a record, because 6 <= the flattening
 * limit. Assuming rate's convention here passes a float where a pointer is read, and the
 * Canonical ABI does not error on that — it returns garbage (AFD-043).
 * Every number above is CHECKED against meld's signature manifest by
 * tools/abi/check-manifest.py rather than trusted from this comment.
 *
 * WHY THE ESTIMATOR AT ALL: jess's on-target differential has only ever invoked rate and
 * mixer. ekf, attitude and position sit in the fused image and are never called — and
 * relay's estimator fix, the change behind v1.134 -> v1.139, lives in that blind spot
 * (AFD-122). Renamed by objcopy for the same '@'-begins-an-ARM-comment reason as the others. */
extern int jess_ekf_estimate(float ax, float ay, float az, float gx, float gy, float gz);

/* jess's OWN imu-sample, byte-identical to ekf_ref.py's IMU_SAMPLE. No upstream vector
 * exists to inherit (relay#376 is where one would come from, still unanswered), so this must
 * not be cited as relay's. A level hover: the accelerometer reads gravity on one axis, and
 * the gyro carries the SAME body rates as ARGV_WORDS' wx/wy/wz below — note the three words
 * are bit-identical there, so the two vectors describe one vehicle rather than two. */
static const jess_u32 IMU_WORDS[6] = {
    0x00000000u,   /* ax  0     */
    0x00000000u,   /* ay  0     */
    0xC11CF5C3u,   /* az -9.81  */
    0x3E99999Au,   /* gx  0.3   == ARGV_WORDS[10] wx */
    0xBE19999Au,   /* gy -0.15  == ARGV_WORDS[11] wy */
    0x3D8F5C29u,   /* gz  0.07  == ARGV_WORDS[12] wz */
};

/* Bit-cast without libc. A union is the well-defined route in C99; memcpy may not exist in
 * a freestanding cross toolchain (AFD-051), and a pointer cast through float* would be a
 * strict-aliasing violation the optimiser is entitled to reorder. */
static float jess_bits_to_f32(jess_u32 w)
{
    union { jess_u32 u; float f; } c;
    c.u = w;
    return c.f;
}

/* The SIL reference vector — byte-identical to tools/cascade-differential/cascade_ref.py.
 * Sharing it is the point: the ARM result is then directly comparable to the number
 * wasmtime already produces, so a wrong embedder register shows up as a wrong torque
 * rather than as a plausible-looking one. */
static const jess_u32 ARGV_WORDS[18] = {
    0x3F800000u,0x00000000u,0x00000000u,0x00000000u,   /* qw qx qy qz */
    0x00000000u,0x00000000u,0xC0200000u,               /* pos n e d   */
    0x3DCCCCCDu,0xBE4CCCCDu,0x3D4CCCCDu,               /* vel n e d   */
    0x3E99999Au,0xBE19999Au,0x3D8F5C29u,               /* wx wy wz    */
    0x00000000u,                                       /* innovation  */
    0x3F800000u,0x00000000u,0x00000000u,0x3F000000u    /* rx ry rz thrust */
};

void jess_init(void)
{
    /* (1) the data-segment promise (#1041) */
    for (jess_usize s = 0; s < jess_wasm_data_seg_count; ++s) {
        const jess_seg_t *g = &jess_wasm_data_segs[s];
        for (jess_u32 i = 0; i < g->len; ++i)
            LINMEM[g->dst + i] = jess_wasm_data_blob[g->off + i];
    }
    /* (2) the R9 globals promise (#1052), in declaration order — the order synth's own
     * reset handler seeds them in, verified like-for-like on this module (AFD-056). */
    for (jess_usize i = 0; i < jess_wasm_global_count; ++i)
        GLOBALS[i] = jess_wasm_global_init[i];

    /* PAINT THE SHADOW-STACK REGION — after init, before the call.
     *
     * AFD-055 concluded painting could not measure this image's stack because the reset
     * handler's copy overwrites the paint. That was true of the SELF-CONTAINED image,
     * where jess had no control over the sequence. Here the harness owns it: init runs
     * first, then the paint, then the call. So a true high-water becomes measurable.
     *
     * The region painted is [PAINT_LO, PAINT_HI) — below the shadow-stack pointer's
     * initial value (global 0 = 8192 = 0x2000) and above the static data top, which is
     * where a downward-growing shadow stack must land.
     *
     * 0xDEADBEEF and not zero: a difference-based measurement cannot see a store that
     * writes a value already present, so it yields a LOWER BOUND. A distinctive pattern
     * makes "was this byte touched" answerable rather than inferable. */
    for (jess_u32 a = PAINT_LO; a < PAINT_HI; a += 4)
        *(volatile jess_u32 *)(LINMEM + a) = 0xDEADBEEFu;

    /* the argument vector, at the offset boot.S passes in r0 */
    volatile jess_u32 *a = (volatile jess_u32 *)(LINMEM + ARGOFF);
    for (int i = 0; i < 18; ++i) a[i] = ARGV_WORDS[i];
}

int jess_call_rate(int arg) { return jess_rate_tick(arg); }

/* The two-stage chain: rate -> mixer, with the data flowing between them ON TARGET rather
 * than being re-supplied by the harness. Returns the wasm offset of the motor-pwm record.
 *
 * The torque is read back from rate's return area at LINMEM + off, then passed FLATTENED,
 * which is the whole reason this is a distinct rung from the single-stage call. */
int jess_call_chain(int arg)
{
    int t = jess_rate_tick(arg);
    const volatile float *q = (const volatile float *)(LINMEM + (unsigned)t);

    /* Park the INTERMEDIATE torque here, from this same single invocation. Calling
     * rate#tick a second time to observe it would return a DIFFERENT value — the cascade
     * integrates, so tick 2 != tick 1. That is the statefulness that made AFD-048's
     * negative control measure the wrong property. */
    volatile jess_u32 *r = (volatile jess_u32 *)0x20011000u;
    const volatile jess_u32 *w = (const volatile jess_u32 *)(LINMEM + (unsigned)t);
    r[0] = (jess_u32)t; r[1] = w[0]; r[2] = w[1]; r[3] = w[2]; r[4] = w[3];

    return jess_mixer_mix(q[0], q[1], q[2], q[3]);
}

/* ---------------------------------------------------------------------------
 * TEST-PIX-033 — the N-TICK SOAK.
 *
 * AFD-060 executed ONE invocation. One invocation cannot distinguish a correctly
 * lowered integrator from one whose state update was dropped: both produce the same
 * first tick. This runs the chain N times and folds every motor-pwm word, so the
 * evolution itself is the observable.
 *
 * The soak gets its OWN image (boot-soak.S). The chain image has already advanced the
 * cascade one tick by the time it returns, so appending a soak to it would offset every
 * tick against the wasmtime reference by one — the same class of mistake as calling
 * rate#tick twice in AFD-060.
 *
 * The fold is FNV-1a over the four pwm words of EVERY tick, in order. It is
 * order-sensitive and cheap, and tools/cascade-differential/soak_ref.py computes it with
 * the identical constants so a divergence is a lowering defect, not a fold difference.
 *
 * NON-VACUITY, established in wasmtime BEFORE this was written: tick 1 is a large
 * transient (m1 0x00000000) and ticks 2..N drift monotonically (m1 0x3ED9565C ->
 * 0x3ED89353 over 64). A build that froze the integrator would repeat tick 2 forever and
 * the fold would diverge. Both endpoints are parked so that is visible, not just folded. */
#define SOAK_BASE 0x20011200u
#define FNV_OFF   2166136261u
#define FNV_PRIME 16777619u

void jess_call_soak(int arg, int n)
{
    volatile jess_u32 *o = (volatile jess_u32 *)SOAK_BASE;
    jess_u32 h = FNV_OFF;
    jess_u32 iters = 0;          /* the TRIP COUNT, incremented inside the loop */

    for (int i = 1; i <= n; ++i) {
        ++iters;
        int t = jess_rate_tick(arg);
        const volatile float *q = (const volatile float *)(LINMEM + (unsigned)t);
        int p = jess_mixer_mix(q[0], q[1], q[2], q[3]);
        const volatile jess_u32 *w = (const volatile jess_u32 *)(LINMEM + (unsigned)p);

        for (int k = 0; k < 4; ++k) { h ^= w[k]; h *= FNV_PRIME; }

        if (i == 1) { o[1] = w[0]; o[2] = w[1]; o[3] = w[2]; o[4] = w[3]; }
        if (i == n) { o[5] = w[0]; o[6] = w[1]; o[7] = w[2]; o[8] = w[3]; }
    }
    /* o[0] is the OBSERVED trip count, not the requested n. Writing n before the loop
     * (as this did originally) proves only that the constant was passed — a soak that
     * ran once would report 64. Clean-room verification caught that, and also showed a
     * STATIC "does jess_call_soak contain a backward branch" check cannot distinguish
     * the outer soak loop from the inner 4-word fold loop. A counter the loop itself
     * increments is the only form of this evidence that -O2 cannot restructure away. */
    o[0]  = iters;
    o[9]  = h;
    o[10] = 0x1E55B0A5u;   /* completion sentinel — distinct from the chain's */
}

/* ---------------------------------------------------------------------------
 * TEST-PIX-036 — the ESTIMATOR on target, N ticks.
 *
 * Its own image (boot-ekf.S) and its own parking area, for the same reason the soak got
 * one: TEST-PIX-032 carries the only FROZEN baseline in the suite — EXP/EXPP in
 * run-oracle.sh, derived from relay's SIL reference under v1.134.1 and still passing
 * bit-exact on v1.139 (AFD-122). Adding a call into that image would advance shared state
 * and move the one number in this repo that is not recomputed from the module under test.
 * Nothing here may touch it.
 *
 * WHY N TICKS AND NOT ONE, established in wasmtime BEFORE this was written:
 *   - the estimator INTEGRATES (tick1 != tick2 != tick3), so one tick cannot tell a correct
 *     lowering from one whose state update was dropped;
 *   - five of the fourteen state fields (pos-n/e/d, vel-d, innovation) are IDENTICALLY ZERO
 *     at tick1 and become nonzero by tick2. A single-tick oracle would fold five constants
 *     and call it coverage.
 *
 * The fold is FNV-1a over all FOURTEEN words of EVERY tick, in order — not just the
 * quaternion, because the position and velocity integration is exactly what those five
 * zero-at-tick-1 fields carry. ekf_ref.py uses identical constants, so a divergence is a
 * lowering defect rather than a fold difference. */
#define EKF_BASE 0x20011400u

void jess_call_ekf(int n)
{
    volatile jess_u32 *o = (volatile jess_u32 *)EKF_BASE;
    jess_u32 h = FNV_OFF;
    jess_u32 iters = 0;

    const float ax = jess_bits_to_f32(IMU_WORDS[0]);
    const float ay = jess_bits_to_f32(IMU_WORDS[1]);
    const float az = jess_bits_to_f32(IMU_WORDS[2]);
    const float gx = jess_bits_to_f32(IMU_WORDS[3]);
    const float gy = jess_bits_to_f32(IMU_WORDS[4]);
    const float gz = jess_bits_to_f32(IMU_WORDS[5]);

    for (int i = 1; i <= n; ++i) {
        ++iters;
        /* SIX FLATTENED f32 — not a pointer. See the extern's note. */
        int sp = jess_ekf_estimate(ax, ay, az, gx, gy, gz);
        const volatile jess_u32 *w = (const volatile jess_u32 *)(LINMEM + (unsigned)sp);

        for (int k = 0; k < 14; ++k) { h ^= w[k]; h *= FNV_PRIME; }

        if (i == 1) { for (int k = 0; k < 14; ++k) o[1 + k]  = w[k]; }
        if (i == n) { for (int k = 0; k < 14; ++k) o[15 + k] = w[k]; }
    }
    /* o[0] is the OBSERVED trip count, incremented inside the loop — not the requested n.
     * Writing n before the loop proves only that the constant arrived (AFD-060). */
    o[0]  = iters;
    o[29] = h;
    o[30] = 0x1E55E4F0u;   /* completion sentinel — distinct from the chain's and the soak's */
}
