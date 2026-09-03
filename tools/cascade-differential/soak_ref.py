#!/usr/bin/env python3
"""N-tick soak reference — the numbers the LOWERED ARM must match over a whole run.

sil_reference.py pins ONE tick. One tick cannot distinguish a correctly lowered
integrator from one whose state update was dropped: both produce the same first tick.
This runs the same fused core module in wasmtime for N ticks and folds every motor-pwm
word, so the EVOLUTION is the observable.

Same module, two backends — any divergence is a lowering defect, not a modelling
difference (DD-026 P2). No plant model is integrated here: the input vector is held
constant and the cascade's OWN integrator state is what makes tick i differ from tick
i-1. Closing the loop around a vehicle model is relay's SIL, not jess's.

Usage:  soak_ref.py <module.wasm> <N> [--format json]
"""
import struct, sys, json

RATE  = "pulseengine:falcon-cascade/rate@0.7.0#tick"
MIXER = "pulseengine:falcon-cascade/mixer@0.7.0#mix"

# Byte-identical to harness.c's ARGV_WORDS and cascade_ref.py's vector. Deliberately
# non-symmetric: a symmetric or all-zero input is a vacuous differential, reproducible
# by a miscompile that drops terms.
VEHICLE_STATE = [1.0, 0.0, 0.0, 0.0,  0.0, 0.0, -2.5,  0.1, -0.2, 0.05,
                 0.30, -0.15, 0.07,  0.0]
RATE_SETPOINT = [1.0, 0.0, 0.0, 0.5]

FNV_OFF, FNV_PRIME, MASK = 2166136261, 16777619, 0xFFFFFFFF


def soak(module_path, n):
    # Imported lazily so --self-test (which exercises the vacuity guard, not the runtime)
    # works without wasmtime installed. A self-test that cannot run is not a self-test.
    from wasmtime import Store, Module, Instance
    store = Store()
    inst = Instance(store, Module.from_file(store.engine, module_path), [])
    ex = inst.exports(store)
    mem, tick, mix = ex["memory"], ex[RATE], ex[MIXER]

    argp = (ex["__heap_base"].value(store) + 0xF) & ~0xF
    mem.write(store, struct.pack("<14f", *VEHICLE_STATE) + struct.pack("<4f", *RATE_SETPOINT), argp)

    h = FNV_OFF
    first = last = None
    for i in range(1, n + 1):
        r = tick(store, argp)
        p = mix(store, *struct.unpack("<4f", mem.read(store, r, r + 16)))
        w = struct.unpack("<4I", mem.read(store, p, p + 16))
        for k in w:
            h = ((h ^ k) * FNV_PRIME) & MASK
        if i == 1:
            first = w
        last = w
    return {"n": n, "tick1": list(first), "tickN": list(last), "fold": h}


def vacuous(r):
    """A soak whose endpoints are equal observes nothing: it would be reproduced exactly by
    a build that froze the integrator after the first tick. Such a result must never be
    emitted as a reference."""
    return r["n"] > 1 and r["tick1"] == r["tickN"]


def self_test():
    """Make the vacuity guard's FAILING case observable. A guard that has never been seen
    to fire is indistinguishable from one that cannot (AFD-048, AFD-062)."""
    frozen = {"n": 64, "tick1": [1, 2, 3, 4], "tickN": [1, 2, 3, 4], "fold": 0}
    moving = {"n": 64, "tick1": [1, 2, 3, 4], "tickN": [1, 2, 3, 5], "fold": 0}
    single = {"n": 1,  "tick1": [1, 2, 3, 4], "tickN": [1, 2, 3, 4], "fold": 0}
    ok = True
    for name, case, want in (("frozen-integrator", frozen, True),
                             ("evolving", moving, False),
                             ("n=1 (endpoints equal by definition)", single, False)):
        got = vacuous(case)
        mark = "OK " if got == want else "BAD"
        if got != want:
            ok = False
        print(f"  {mark} vacuous({name}) = {got}, want {want}")
    print("  self-test:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main():
    if "--self-test" in sys.argv:
        return self_test()
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) < 2:
        sys.stderr.write(__doc__ or ""); return 2
    r = soak(args[0], int(args[1]))

    if vacuous(r):
        sys.stderr.write(f"REFUSING: tick1 == tickN over {r['n']} ticks — the soak observes nothing\n")
        return 3

    if "--format" in sys.argv and "json" in sys.argv:
        print(json.dumps(r))
    else:
        print(f"  module   {args[0]}")
        print(f"  ticks    {r['n']}")
        print(f"  tick1    {' '.join(f'{w:08X}' for w in r['tick1'])}")
        print(f"  tickN    {' '.join(f'{w:08X}' for w in r['tickN'])}")
        print(f"  fold     {r['fold']:08X}   (FNV-1a over 4*N pwm words, in order)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
