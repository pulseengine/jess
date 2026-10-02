#!/usr/bin/env python3
"""Is the lowered cascade's down-axis velocity UNCOMPENSATED GRAVITY? Measure it, per tick.

WHY THIS IS THE SHARPEST THING TO MEASURE. AFD-125 says four of fourteen returned state words
disagree with wasmtime. That is a true statement and a weak one: it names no term. This fits the
down-axis velocity against a closed form instead, and the fit is unambiguous.

A strapdown inertial update computes, per tick, roughly
    v_nav += (R(q) * a_body + g_nav) * dt
where the `+ g_nav` is the GRAVITY COMPENSATION: an accelerometer at rest reads specific force
(+1 g upward), and the compensation cancels it so a stationary vehicle integrates ~zero velocity.
Drop that term and the vehicle appears to accelerate downward at g forever, so
    vel-d(n) = n * g * dt        exactly, to within the attitude's drift off identity.

MEASURED on the 16-tick ekf run, IMU (0, 0, -9.81, 0.30, -0.15, 0.07):
    the lowered ARM run   vel-d(n) / (n*g*dt) = 1.0000 .. 1.0003 for n = 1..16
    wasmtime              vel-d(16) = -1.87e-08, i.e. cancelled to eight decimal places
So the lowered code behaves as though the compensation term contributed nothing, and wasmtime
behaves as though it contributed exactly what cancels gravity. A ratio that tracks n so closely
over sixteen ticks is not a rounding difference and not a stale read; it is one missing or
zero-valued addend.

AND IT EXPLAINS THE SIGN PATTERN that the whole-memory diff found (AFD-134): with gravity
uncancelled the translational sub-vector is dominated by a term of definite sign, while
wasmtime's residuals are the small tilt corrections of the opposite sign. Six of six differing
fields disagreeing in sign is what that looks like downstream.

A CORRECTION I MADE WHILE WRITING THIS, kept because the error is seductive. My first reading of
the tick-1 numbers was that ARM matched the physics and wasmtime did not: with an identity
attitude, gravity on the body z axis "should" appear on the down axis, and ARM's value is g*dt to
1 ulp. That is the physics of FREE FALL, not of a compensated inertial update. For a vehicle at
rest the correct answer is ~zero, which is wasmtime's. Getting this backwards would have inverted
the whole finding and sent an upstream report in the wrong direction.

WHAT THIS DOES NOT ESTABLISH. That the term is missing in the LOWERING rather than in the module
is not shown here — wasmtime defines the semantics, so wasmtime's behaviour IS the module's, and
the lowered run deviating from it localises the defect to the lowering. But which instruction,
and whether the addend is absent, zeroed, or landing on another axis, needs the disassembly. This
measures the symptom precisely; it does not name the instruction.

Usage:
  gravity-residual.py (--trace <memtrace> [--addr 2000b048] | --arm-words <file>) [--ticks 16]
                      [--module <wasm>] [--g 9.81 --dt 1e-3] [--tol 0.01]
  gravity-residual.py --self-test
Exit: 0 compensated on both sides, 1 one side is uncompensated, 2 CANNOT DETERMINE.
"""
import struct
import sys

CANNOT = 2
UNCOMP, COMP, NEITHER = "UNCOMPENSATED", "COMPENSATED", "NEITHER"


def f32(bits):
    return struct.unpack("<f", struct.pack("<I", bits))[0]


def classify(series, g, dt, tol):
    """series: vel-d per tick, tick 1 first. -> (verdict, ratios).

    THREE OUTCOMES, not two. A classifier with only "uncompensated" and "compensated" would have
    to put anything else in one of them, and the interesting failure — a series that is neither —
    would be reported as whichever bucket was the default. So NEITHER is a real answer.
    """
    ratios = []
    for n, v in enumerate(series, 1):
        expect = n * g * dt
        ratios.append(v / expect if expect else float("inf"))
    if all(abs(r - 1.0) <= tol for r in ratios):
        return UNCOMP, ratios
    # Compensated means small compared with the gravity term it should have cancelled, judged
    # against that term rather than against an absolute epsilon, so it scales with g and dt.
    if all(abs(v) <= tol * g * dt for v in series):
        return COMP, ratios
    return NEITHER, ratios


def arm_series(trace, addr, ticks):
    vals = []
    with open(trace, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            p = line.split()
            if len(p) == 6 and p[2] == addr and p[4] == "W" and p[3] == "4":
                vals.append(int(p[5], 16))
    if len(vals) != ticks:
        return None, (f"found {len(vals)} write(s) to {addr}, expected {ticks}. A series of the "
                      f"wrong length would be fitted against the wrong n, so the ratio would be "
                      f"meaningless while still printing neatly.")
    return [f32(v) for v in vals], None


def wasmtime_series(module, ticks, imu, field_index=9):
    from wasmtime import Store, Module, Instance
    store = Store()
    inst = Instance(store, Module.from_file(store.engine, module), [])
    ex = inst.exports(store)
    name = next(n for n in (list(ex._extern_map) if hasattr(ex, "_extern_map") else [])
                if n.endswith("ekf@0.10.0#estimate"))
    mem = ex["memory"]
    out = []
    for _ in range(ticks):
        p = ex[name](store, *imu)
        words = struct.unpack("<14I", mem.read(store, p, p + 56))
        out.append(f32(words[field_index]))
    return out


def self_test():
    g, dt, tol = 9.81, 1e-3, 0.01
    ok = True
    cases = [
        ("exactly n*g*dt",      [n * g * dt for n in range(1, 17)],          UNCOMP),
        ("n*g*dt +0.03% drift", [n * g * dt * (1 + 0.0003) for n in range(1, 17)], UNCOMP),
        ("cancelled to ~1e-8",  [-1.87e-08] * 16,                            COMP),
        ("exactly zero",        [0.0] * 16,                                  COMP),
        # THE CONTROL THAT STOPS THE OTHER TWO BEING VACUOUS: a series that is neither must be
        # reported as neither. Without it, a classifier that answered UNCOMPENSATED always would
        # pass case 1, and one that answered COMPENSATED always would pass case 3.
        ("half of n*g*dt",      [0.5 * n * g * dt for n in range(1, 17)],    NEITHER),
        ("quadratic, not linear", [n * n * g * dt for n in range(1, 17)],    NEITHER),
    ]
    for name, series, want in cases:
        got, _ = classify(series, g, dt, tol)
        if got == want:
            print(f"  {name:24} {got:14} OK")
        else:
            print(f"  {name:24} {got:14} want {want} FAIL")
            ok = False
    # A wrong-length series must be refused rather than fitted.
    print("  self-test: " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()

    def opt(name, d):
        return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else d

    trace = opt("--trace", None)
    # --arm-words lets the measured series be re-checked from COMMITTED EVIDENCE. The trace it
    # came from is ~20 MB and is not committed; sixteen hex words are, in
    # repro/synth-1436/veld-arm-16ticks.txt. So "re-run jess's fit" costs a second and needs no
    # emulator, which is the difference between a finding someone can check and one they have to
    # take on trust.
    arm_words = opt("--arm-words", None)
    addr = opt("--addr", "2000b048")          # return area 0x2000b024 + 9*4, the vel-d slot
    ticks = int(opt("--ticks", "16"))
    module = opt("--module", None)
    g = float(opt("--g", "9.81"))
    dt = float(opt("--dt", "1e-3"))
    tol = float(opt("--tol", "0.01"))
    imu = [float(x) for x in opt("--imu", "0.0,0.0,-9.81,0.30,-0.15,0.07").split(",")]

    if not trace and not module and not arm_words:
        print(__doc__)
        return CANNOT

    verdicts = {}
    if arm_words:
        txt = open(arm_words, encoding="utf-8").read() if "." in arm_words or "/" in arm_words \
            else arm_words
        # Strip whole COMMENT LINES, not words beginning with '#'. The first version did the
        # latter and fed the comment prose into the fit, which the length guard then refused
        # with "76 words, expected 16" — the guard doing its job on the reader's own bug.
        lines = [ln.split("#", 1)[0] for ln in txt.splitlines()]
        ws = " ".join(lines).replace(",", " ").split()
        if len(ws) != ticks:
            print(f"  CANNOT DETERMINE (ARM side): {len(ws)} word(s) given, expected {ticks}.")
            return CANNOT
        s = [f32(int(w, 16)) for w in ws]
        v, ratios = classify(s, g, dt, tol)
        verdicts["lowered (ARM, from committed words)"] = (v, s, ratios)
    if trace:
        s, err = arm_series(trace, addr, ticks)
        if err:
            print(f"  CANNOT DETERMINE (ARM side): {err}")
            return CANNOT
        v, ratios = classify(s, g, dt, tol)
        verdicts["lowered (ARM, from the trace)"] = (v, s, ratios)
    if module:
        try:
            s = wasmtime_series(module, ticks, imu)
        except ImportError as e:
            print(f"  CANNOT DETERMINE (wasmtime side): {e}")
            return CANNOT
        v, ratios = classify(s, g, dt, tol)
        verdicts["wasmtime"] = (v, s, ratios)

    print(f"== vel-d against n*g*dt, g={g} dt={dt} over {ticks} ticks, tol {tol:.1%} ==")
    for who, (v, s, ratios) in verdicts.items():
        print(f"\n  {who}: {v}")
        print("    tick      vel-d        n*g*dt       ratio")
        for n, (x, r) in enumerate(zip(s, ratios), 1):
            if n <= 3 or n >= ticks - 1:
                print(f"    {n:4}   {x:+.6e}   {n * g * dt:.6e}   {r:8.4f}")
            elif n == 4:
                print("     ...")

    if UNCOMP in (v for v, _, _ in verdicts.values()):
        print("\n  A side whose vel-d tracks n*g*dt over every tick is integrating gravity")
        print("  WITHOUT the compensation term. That is one missing or zero-valued addend, not a")
        print("  rounding difference and not a stale read.")
        return 1
    if all(v == COMP for v, _, _ in verdicts.values()):
        print("\n  Both sides cancel gravity. Whatever AFD-125 is about, it is not this term.")
        return 0
    print("\n  At least one side is NEITHER — it does not track n*g*dt and is not cancelled")
    print("  either. Do not fold that into 'the gravity term is missing'; it is a third thing.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
