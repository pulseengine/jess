#!/usr/bin/env python3
"""N-tick reference for the falcon ESTIMATOR — the stage jess's on-target differential
has never invoked.

WHY THIS EXISTS. jess's on-target differential covers rate -> mixer. The other three
stages (ekf, attitude, position) are present in the fused image and are NEVER CALLED, so
no jess measurement has ever observed them on a target. relay's estimator fix — the change
that invalidated 18 of their closed-loop tests and forced the v1.134 -> v1.139 move — lives
in exactly that blind spot. AFD-122 recorded that TEST-PIX-032's frozen baseline still
passes bit-exact on v1.139, and also that this says nothing about the stages jess does not
call. This closes the estimator half of that gap.

WHY THE ESTIMATOR IS A BETTER ORACLE THAN THE ONE jess ALREADY HAS. Measured in wasmtime
before any ARM code was written (the order the soak comment prescribes):

    stateful      tick1 != tick2 != tick3 — it integrates, so an N-tick fold observes the
                  state update and not just the arithmetic
    deterministic a fresh instance reproduces tick1 exactly
    all 6 inputs  LIVE. Perturbing any one of ax/ay/az/gx/gy/gz moves 5-8 of the 14 output
                  fields. Compare the composed-app oracle, whose own scope line reports
                  that only 4 of its 18 input scalars move the fold — there, 14 inputs are
                  inert and a negative control on one of them proves nothing. Here every
                  input is attributive.
    coverage      5 of the 14 output fields (pos-n/e/d, vel-d, innovation) are identically
                  zero at tick1 and become nonzero by tick2, so a single-tick oracle would
                  fold five constants. N > 1 is required, not merely nicer.

Canonical ABI, read from meld's signature manifest rather than assumed (AFD-120):
    ekf@<ver>#estimate : (param f32 f32 f32 f32 f32 f32) -> (result i32)
    6 flattened f32 in (6 <= the flattening limit of 16, so NO pointer), and the 14-field
    vehicle-state comes back through a 56-byte return area, align 4, realloc:false.
    NOTE THE CONTRAST with rate#tick, which takes a POINTER because 18 > 16. The cascade
    uses all three shapes and assuming one of them passes garbage silently.

Same module, two backends — any divergence is a lowering defect, not a modelling
difference (DD-026 P2). No plant model: the IMU sample is held constant and the estimator's
OWN state is what makes tick i differ from tick i-1. Closing a loop around a vehicle model
is relay's SIL, not jess's.

Usage:  ekf_ref.py <module.wasm> <N> [--format json] [--imu a,b,c,d,e,f]
        ekf_ref.py --self-test
"""
import struct, sys, json

from ifacever import find_export
EKF_SUFFIX = "ekf#estimate"

# jess's OWN choice of input vector, and said so plainly: unlike VEHICLE_STATE in
# soak_ref.py — which is byte-identical to relay's SIL reference — no upstream IMU sample
# exists to inherit. relay#376 (per-stage reference vectors, still unanswered) is where one
# would come from. Until then this is jess's vector and must not be cited as relay's.
#
# Chosen to be physically sensible and non-degenerate: a level hover, so the accelerometer
# reads gravity on one axis only, and the gyro carries the SAME body rates as
# VEHICLE_STATE's wx/wy/wz so the two vectors describe one vehicle. Deliberately
# non-symmetric and non-zero — a symmetric or all-zero input is a vacuous differential,
# reproducible by a miscompile that drops terms.
IMU_SAMPLE = [0.0, 0.0, -9.81, 0.30, -0.15, 0.07]

STATE_FIELDS = ["qw", "qx", "qy", "qz", "pos-n", "pos-e", "pos-d",
                "vel-n", "vel-e", "vel-d", "wx", "wy", "wz", "innovation"]
STATE_WORDS = 14
RETURN_AREA = 56          # asserted against the manifest by tools/abi/check-manifest.py

FNV_OFF, FNV_PRIME, MASK = 2166136261, 16777619, 0xFFFFFFFF


def estimate_n(module_path, n, imu=None):
    # Imported lazily so --self-test (which exercises the guards, not the runtime) works
    # without wasmtime installed. A self-test that cannot run is not a self-test.
    from wasmtime import Store, Module, Instance
    imu = list(imu or IMU_SAMPLE)
    store = Store()
    inst = Instance(store, Module.from_file(store.engine, module_path), [])
    ex = inst.exports(store)
    names = list(ex._extern_map) if hasattr(ex, "_extern_map") else []
    EKF = find_export(names, EKF_SUFFIX)
    mem = ex["memory"]

    h = FNV_OFF
    first = last = None
    for i in range(1, n + 1):
        p = ex[EKF](store, *imu)
        words = struct.unpack(f"<{STATE_WORDS}I", mem.read(store, p, p + RETURN_AREA))
        # Fold EVERY field of EVERY tick, in order. Folding only the quaternion would miss
        # the position and velocity integration, which is the part five fields start at
        # zero for.
        for w in words:
            h = ((h ^ w) * FNV_PRIME) & MASK
        if i == 1:
            first = list(words)
        last = list(words)
    return {"n": n, "imu": imu, "tick1": first, "tickN": last, "fold": h}


def vacuous(r):
    """Two ways this oracle can observe nothing, both of which a plausible miscompile
    reproduces exactly:

      frozen state   tick1 == tickN over n > 1 ticks. A build that dropped the estimator's
                     state update produces precisely this, and every tick would be tick 1.
      dead output    every folded word identical across the whole run, i.e. tickN is all
                     one repeated value. A lowering that returned a constant record passes
                     a bit-exactness check against a reference that made the same mistake
                     only if the reference shares the defect — but it would sail through a
                     fold comparison against itself, so refuse to publish it as a reference.
    """
    if r["n"] > 1 and r["tick1"] == r["tickN"]:
        return "tick1 == tickN"
    if len(set(r["tickN"])) == 1:
        return "every field of tickN is the same word"
    return None


def self_test():
    """Make each guard's FAILING case observable. A guard that has never been seen to fire
    is indistinguishable from one that cannot (AFD-048, AFD-062, AFD-124)."""
    ok = True
    A = list(range(1, 15))              # 14 distinct words
    B = list(range(2, 16))
    cases = [
        ("frozen integrator",              {"n": 16, "tick1": A, "tickN": A,       "fold": 0}, "tick1 == tickN"),
        ("evolving (the real shape)",       {"n": 16, "tick1": A, "tickN": B,       "fold": 0}, None),
        ("n=1 (endpoints equal by defn)",   {"n": 1,  "tick1": A, "tickN": A,       "fold": 0}, None),
        ("dead output, all one word",       {"n": 16, "tick1": A, "tickN": [7]*14,  "fold": 0}, "every field of tickN is the same word"),
    ]
    for name, case, want in cases:
        got = vacuous(case)
        good = (got == want)
        ok &= good
        print(f"  {'OK ' if good else 'BAD'} vacuous({name}) = {got!r}, want {want!r}")
    # The ABI constant must not drift from the manifest silently.
    good = RETURN_AREA == STATE_WORDS * 4
    ok &= good
    print(f"  {'OK ' if good else 'BAD'} return area {RETURN_AREA} B == {STATE_WORDS} fields x 4 B")
    print("  self-test:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main():
    if "--self-test" in sys.argv:
        return self_test()
    imu = None
    if "--imu" in sys.argv:
        imu = [float(x) for x in sys.argv[sys.argv.index("--imu") + 1].split(",")]
        if len(imu) != 6:
            sys.stderr.write("--imu needs exactly 6 comma-separated floats\n")
            return 2
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--imu" in sys.argv:
        args = [a for a in args if a != sys.argv[sys.argv.index("--imu") + 1]]
    if len(args) < 2:
        sys.stderr.write(__doc__ or "")
        return 2
    r = estimate_n(args[0], int(args[1]), imu)

    why = vacuous(r)
    if why:
        sys.stderr.write(f"REFUSING: {why} over {r['n']} ticks — this reference observes nothing\n")
        return 3

    if "--format" in sys.argv and "json" in sys.argv:
        print(json.dumps(r))
    else:
        print(f"  module   {args[0]}")
        print(f"  ticks    {r['n']}")
        print(f"  imu      ax={r['imu'][0]:g} ay={r['imu'][1]:g} az={r['imu'][2]:g} "
              f"gx={r['imu'][3]:g} gy={r['imu'][4]:g} gz={r['imu'][5]:g}")
        for lab, w in (("tick1", r["tick1"]), ("tickN", r["tickN"])):
            print(f"  {lab}")
            for f, v in zip(STATE_FIELDS, w):
                fv = struct.unpack("<f", struct.pack("<I", v))[0]
                print(f"      {f:11s} {v:08X}  {fv:.9g}")
        print(f"  fold     {r['fold']:08X}   (FNV-1a over {STATE_WORDS}*N state words, in order)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
