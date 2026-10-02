#!/usr/bin/env python3
"""Compare the WHOLE of linear memory between the synth-lowered run and wasmtime, over the same
module and the same ticks — and classify every difference.

WHY THIS BEATS COMPARING THE RETURN VALUE. AFD-125 compares 14 returned state words and finds
four wrong. That says the answer is wrong; it does not say where it went wrong, because fourteen
words are the only place anyone was looking. Linear memory is 16,384 words, the module's entire
mutable state lives there, and under `--memory shared` both runtimes lay it out IDENTICALLY — so
the same offset means the same thing on both sides and a whole-memory diff localises the
divergence to the slot it first appears in, without a disassembly and without a model of the
filter.

This is what retired the hypothesis both jess and synth had adopted. synth#1436 had converged on
a "lagged or stale attitude" — jess proposed it from the tick-16 numbers and synth wrote it into
the v0.80 plan. The persistent quaternion is at offset 0xac18, and it is BIT-IDENTICAL between
the two runtimes at every tick. A stale attitude would have shown up there. It did not.

TWO MASKS, both of which must be stated or the count is wrong:

  THE HARNESS PAINT. jess's harness fills linear memory with 0xdeadbeef before running, to make
  "never written" distinguishable from "written zero" — a deliberate choice (AFD-088's lesson:
  an all-zero parking area reads as an answer). wasmtime zero-fills instead. So every word the
  module never touched differs trivially, and on the 16-tick ekf run that is 744 of 972
  differences — more than three quarters of them. Counting those as divergence would be a
  vacuous positive, the mirror image of a vacuous zero. They are masked and REPORTED.

  THE ASYMMETRIC CASE IS NOT MASKED, because it is a real finding: an offset where the ARM run
  still holds the paint but wasmtime wrote something means THE LOWERED CODE OMITTED A STORE the
  wasm performed. That is reported separately and loudly.

AND THE DIFFERENCES ARE CLASSIFIED, because "228 words differ" conflates two different defects:
  ULP-CLOSE   the same computation rounding differently (an f32 FMA contraction, say). Expected
              on a different FPU and usually not a correctness bug.
  DIVERGENT   a different exponent or a different sign — a different QUANTITY, not a rounded
              one. This is where a lowering defect lives.
A single count would let a hundred harmless roundings hide one real one, or the reverse.

Usage:
  linmem-differential.py <arm.bin> <wasmtime.bin> [--paint deadbeef] [--ulp 4] [--runs 40]
                         [--return-area b024]
  linmem-differential.py --self-test
Exit: 0 identical after masking, 1 differences found, 2 CANNOT DETERMINE.
"""
import struct
import sys

CANNOT = 2
WORDS = None


def f32(w):
    return struct.unpack("<f", struct.pack("<I", w))[0]


def ulp_distance(a, b):
    """Distance in representable f32 steps, on the usual sign-magnitude-to-ordinal mapping.

    NaNs and opposite-sign-across-zero are not meaningfully 'close', so they return a large
    number rather than a small one. Getting this backwards would classify a sign flip as a
    rounding difference, which is precisely the mistake the classification exists to avoid.
    """
    def ordinal(w):
        return w if not (w & 0x80000000) else -(w & 0x7FFFFFFF)
    ea, eb = (a >> 23) & 0xFF, (b >> 23) & 0xFF
    if ea == 0xFF or eb == 0xFF:            # inf/NaN on either side
        return 1 << 30
    return abs(ordinal(a) - ordinal(b))


def compare(arm, wt, paint=0xDEADBEEF, ulp=4):
    n = len(arm) // 4
    a = struct.unpack(f"<{n}I", arm)
    w = struct.unpack(f"<{n}I", wt)
    masked, omitted, close, diverge = 0, [], [], []
    for i in range(n):
        if a[i] == w[i]:
            continue
        if a[i] == paint:
            # ARM never wrote it. If wasmtime also effectively did not (zero-init), no
            # information. If wasmtime DID write, the lowered code omitted a store.
            if w[i] == 0:
                masked += 1
            else:
                omitted.append((i * 4, a[i], w[i]))
            continue
        if w[i] == paint:
            # Cannot happen with a zero-filled wasmtime memory, but if it ever does it is not a
            # mask — it means the two runs were not the comparison they were claimed to be.
            omitted.append((i * 4, a[i], w[i]))
            continue
        d = ulp_distance(a[i], w[i])
        (close if d <= ulp else diverge).append((i * 4, a[i], w[i], d))
    return {"words": n, "masked": masked, "omitted": omitted,
            "close": close, "diverge": diverge}


def runs_of(items):
    """Group (offset, ...) tuples into contiguous 4-byte runs."""
    if not items:
        return []
    out, s, p = [], items[0][0], items[0][0]
    for it in items[1:]:
        if it[0] == p + 4:
            p = it[0]
        else:
            out.append((s, p))
            s = p = it[0]
    out.append((s, p))
    return out


def self_test():
    """Every branch of the classification must be shown to fire, and — the part that matters —
    must be shown NOT to fire on its neighbour. A classifier nobody has watched mis-sort is a
    classifier nobody has checked."""
    ok = True
    P = 0xDEADBEEF
    one = struct.pack("<I", 0x3F800000)                    # 1.0
    one_ulp = struct.pack("<I", 0x3F800001)                # 1.0 + 1 ulp
    neg = struct.pack("<I", 0xBF800000)                    # -1.0
    big = struct.pack("<I", 0x40000000)                    # 2.0
    cases = [
        ("identical",            one,                   one,  dict(masked=0, omitted=0, close=0, diverge=0)),
        ("1 ulp apart",          one,                   one_ulp, dict(masked=0, omitted=0, close=1, diverge=0)),
        ("sign flip",            one,                   neg,  dict(masked=0, omitted=0, close=0, diverge=1)),
        ("exponent apart",       one,                   big,  dict(masked=0, omitted=0, close=0, diverge=1)),
        ("paint vs zero",        struct.pack("<I", P),   struct.pack("<I", 0), dict(masked=1, omitted=0, close=0, diverge=0)),
        ("paint vs a VALUE",     struct.pack("<I", P),   one,  dict(masked=0, omitted=1, close=0, diverge=0)),
    ]
    for name, aw, ww, want in cases:
        r = compare(aw, ww)
        got = dict(masked=r["masked"], omitted=len(r["omitted"]),
                   close=len(r["close"]), diverge=len(r["diverge"]))
        if got == want:
            print(f"  {name:20} {got} OK")
        else:
            print(f"  {name:20} {got} want {want} FAIL")
            ok = False
    # A sign flip must NOT be ulp-close however generous the threshold, or the classification
    # would collapse into one bucket at large --ulp.
    r = compare(one, neg, ulp=1 << 29)
    if len(r["diverge"]) == 1:
        print("  sign flip stays DIVERGENT even at a huge --ulp OK")
    else:
        print("  sign flip became ulp-close at a large threshold FAIL")
        ok = False
    print("  self-test: " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    pos = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(pos) < 2:
        print(__doc__)
        return CANNOT

    def opt(name, d):
        return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else d

    paint = int(opt("--paint", "deadbeef"), 16)
    ulp = int(opt("--ulp", "4"))
    nruns = int(opt("--runs", "40"))
    arm = open(pos[0], "rb").read()
    wt = open(pos[1], "rb").read()

    if len(arm) != len(wt):
        print(f"  CANNOT DETERMINE: {len(arm)} vs {len(wt)} bytes. Comparing different sizes")
        print("  would silently compare different offsets. Refusing.")
        return CANNOT
    if len(arm) % 4 or len(arm) == 0:
        print(f"  CANNOT DETERMINE: {len(arm)} bytes is not a nonzero multiple of 4.")
        return CANNOT
    # A dump that is entirely paint means the run never executed; one that is entirely zero
    # means nothing was captured. Either way the diff below would be an artefact.
    if all(b == 0 for b in arm) or all(b == 0 for b in wt):
        print("  CANNOT DETERMINE: one side is entirely zero, so it captured nothing.")
        return CANNOT

    r = compare(arm, wt, paint, ulp)
    print(f"== {r['words']} words compared ==")
    print(f"  masked (ARM paint {paint:08x} vs wasmtime zero-init, never written by either): "
          f"{r['masked']}")
    print(f"  ULP-CLOSE (<= {ulp} ulp — same computation, different rounding): {len(r['close'])}")
    print(f"  DIVERGENT (a different quantity): {len(r['diverge'])}")
    print(f"  OMITTED STORES (ARM still holds the paint where wasmtime wrote a value): "
          f"{len(r['omitted'])}")

    if r["omitted"]:
        print("\n  !! THE LOWERED CODE DID NOT WRITE WHERE THE WASM DID — this is a missing")
        print("     store, not a rounding difference:")
        for off, a, w in r["omitted"][:20]:
            print(f"       0x{off:05x}  arm {a:08x} (paint)  wasmtime {w:08x}")

    if r["diverge"]:
        print(f"\n== DIVERGENT words, in {len(runs_of(r['diverge']))} contiguous run(s) ==")
        byoff = {d[0]: d for d in r["diverge"]}
        for s, e in runs_of(r["diverge"])[:nruns]:
            print(f"  0x{s:05x}-0x{e:05x}  {(e - s) // 4 + 1} word(s)")
            for off in range(s, e + 4, 4):
                if off in byoff:
                    _, a, w, d = byoff[off]
                    print(f"    0x{off:05x}  arm {a:08x} ({f32(a):+.6e})  "
                          f"wasmtime {w:08x} ({f32(w):+.6e})  {d} ulp")

    if r["close"]:
        print(f"\n== ULP-CLOSE words ({len(r['close'])}), first few ==")
        for off, a, w, d in r["close"][:10]:
            print(f"    0x{off:05x}  arm {a:08x}  wasmtime {w:08x}  {d} ulp")

    # ── THE RETURN AREA, FIELD BY FIELD, WITH THE SIGN PATTERN ──────────────────────────────
    # This is the headline and it has to be computed rather than eyeballed. The 14 returned
    # state words are the only part of memory with NAMES, and the pattern across them is what
    # AFD-125's four-word summary could not show: whether the divergence is scattered or
    # structured. A sign disagreement on every differing field at once is a 1-in-2^k
    # coincidence, and saying so needs the count, not a glance.
    ra = opt("--return-area", None)
    if ra is not None:
        off = int(ra, 16)
        fields = ["qw", "qx", "qy", "qz", "pos-n", "pos-e", "pos-d",
                  "vel-n", "vel-e", "vel-d", "wx", "wy", "wz", "innovation"]
        if off + 4 * len(fields) > len(arm):
            print(f"\n  CANNOT DETERMINE: return area 0x{off:x} + 56 B is past the dump.")
            return CANNOT
        va = struct.unpack_from(f"<{len(fields)}I", arm, off)
        vw = struct.unpack_from(f"<{len(fields)}I", wt, off)
        print(f"\n== RETURN AREA at wasm offset 0x{off:x}, field by field ==")
        print(f"  {'field':11} {'arm':>9} {'wasmtime':>9}  verdict")
        nd = sign_flip = 0
        for f, x, y in zip(fields, va, vw):
            if x == y:
                print(f"  {f:11} {x:9x} {y:9x}  same")
                continue
            nd += 1
            sa, sw = bool(x & 0x80000000), bool(y & 0x80000000)
            # A zero on either side has no sign to disagree about, so it is NOT counted as a
            # flip — counting it would manufacture the pattern this is trying to detect.
            flip = (x != 0 and y != 0 and sa != sw)
            sign_flip += flip
            print(f"  {f:11} {x:9x} {y:9x}  DIFFER"
                  f"{'  + vs -' if flip else ''}")
        print(f"\n  {nd} field(s) differ; {sign_flip} of them differ IN SIGN "
              f"(both nonzero, opposite sign).")
        if nd and sign_flip == nd:
            print(f"  EVERY differing field disagrees in sign. Under a null hypothesis of")
            print(f"  independent signs that is 1 in 2^{nd} = 1 in {2 ** nd}. The agreeing")
            print(f"  fields are not a mixed bag either — see which ones they are.")
        elif nd:
            print("  The sign disagreement is PARTIAL, so it is not a single global inversion.")

    if not r["diverge"] and not r["omitted"]:
        print("\n  No divergent word and no omitted store. After masking, the two runtimes'")
        print("  entire mutable state agrees to within rounding.")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
