#!/usr/bin/env python3
"""Independent reference for the COMPOSED flight-app: rate -> mixer, computed
without the component model.

The composed component returns a single folded u32. That is deliberately hard to
fake but also opaque, so this driver recomputes the same fold from the FUSED CORE
MODULE via the canonical ABI — a completely different execution path (core module +
raw pointers, no wac composition, no gust:os). If the two agree, the composition
did not quietly change the arithmetic.

Canonical ABI (from the WIT + the lowered signatures):
    rate@0.7.0#tick : (param i32) -> (result i32)   arg -> 14xf32 state ++ 4xf32 sp
    mixer@0.7.0#mix : (param f32 f32 f32 f32) -> (result i32)   ret -> 4xf32 pwm
"""
import struct, sys
from wasmtime import Store, Module, Instance

MODULE = sys.argv[1] if len(sys.argv) > 1 else ".scratch/v1341/casc_new.loom.wasm"
VEHICLE_STATE = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, -2.5, 0.1, -0.2, 0.05, 0.30, -0.15, 0.07, 0.0]
RATE_SETPOINT = [1.0, 0.0, 0.0, 0.5]


def main():
    store = Store()
    inst = Instance(store, Module.from_file(store.engine, MODULE), [])
    ex = inst.exports(store)
    mem = ex["memory"]
    argp = (ex["__heap_base"].value(store) + 0xF) & ~0xF

    mem.write(store, struct.pack("<14f", *VEHICLE_STATE) + struct.pack("<4f", *RATE_SETPOINT), argp)
    tp = ex["pulseengine:falcon-cascade/rate@0.7.0#tick"](store, argp)
    torque = struct.unpack("<4f", mem.read(store, tp, tp + 16))

    # NOTE the asymmetry: `mix` takes its 4 f32s FLATTENED, while `tick` takes a
    # pointer — 18 scalars exceeds the canonical ABI's flattening limit, 4 does not.
    # Assuming a uniform pointer-in convention here silently passes garbage.
    pp = ex["pulseengine:falcon-cascade/mixer@0.7.0#mix"](store, *torque)
    pwm = struct.unpack("<4f", mem.read(store, pp, pp + 16))

    # The SAME fold the component performs, in f32 to match wasm arithmetic exactly.
    acc32 = struct.unpack("<f", struct.pack("<f", sum(pwm)))[0]
    folded = int(struct.unpack("<f", struct.pack("<f", acc32 * 1000.0))[0]) & 0x7FFFFFFF

    print(f"  module   {MODULE}")
    print(f"  torque   tx={torque[0]:.9g} ty={torque[1]:.9g} tz={torque[2]:.9g} thrust={torque[3]:.9g}")
    print(f"  pwm      m1={pwm[0]:.9g} m2={pwm[1]:.9g} m3={pwm[2]:.9g} m4={pwm[3]:.9g}")
    print(f"  sum      {acc32:.9g}")
    print(f"  EXPECTED FOLDED u32 (low 31 bits): {folded}")

    # NEGATIVE CONTROL. A fold that is the same for every input proves nothing —
    # a miscompile that drops the state entirely would still "match". Perturb one
    # body rate and require the fold to MOVE.
    pert = list(VEHICLE_STATE); pert[10] += 0.05          # wx 0.30 -> 0.35
    mem.write(store, struct.pack("<14f", *pert) + struct.pack("<4f", *RATE_SETPOINT), argp)
    tp2 = ex["pulseengine:falcon-cascade/rate@0.7.0#tick"](store, argp)
    t2 = struct.unpack("<4f", mem.read(store, tp2, tp2 + 16))
    p2 = ex["pulseengine:falcon-cascade/mixer@0.7.0#mix"](store, *t2)
    pwm2 = struct.unpack("<4f", mem.read(store, p2, p2 + 16))
    a2 = struct.unpack("<f", struct.pack("<f", sum(pwm2)))[0]
    f2 = int(struct.unpack("<f", struct.pack("<f", a2 * 1000.0))[0]) & 0x7FFFFFFF
    print(f"  negative control (wx 0.30 -> 0.35): {f2}"
          f"   {'DISTINCT — the fold tracks the input' if f2 != folded else 'IDENTICAL — VACUOUS, fold ignores state'}")
    return 0 if f2 != folded else 1


if __name__ == "__main__":
    sys.exit(main())
