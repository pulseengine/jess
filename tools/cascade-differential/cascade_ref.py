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
    # BIT-EXACT fold: the raw f32 bits, sign dropped. See flight-app's note — the old
    # `int(sum * 1000)` accepted a 0.07% window and let a falsified setpoint pass.
    folded = struct.unpack("<I", struct.pack("<f", acc32))[0] & 0x7FFFFFFF

    print(f"  module   {MODULE}")
    print(f"  torque   tx={torque[0]:.9g} ty={torque[1]:.9g} tz={torque[2]:.9g} thrust={torque[3]:.9g}")
    print(f"  pwm      m1={pwm[0]:.9g} m2={pwm[1]:.9g} m3={pwm[2]:.9g} m4={pwm[3]:.9g}")
    print(f"  sum      {acc32:.9g}")
    print(f"  EXPECTED FOLDED u32 (low 31 bits): {folded}")

    # NEGATIVE CONTROL — REWRITTEN 2026-08-28 after clean-room verification found the
    # original was VACUOUS. Recorded here because the mistake is instructive.
    #
    # The original perturbed wx by +0.05 and re-ticked ON THE SAME INSTANCE, then
    # reported the changed fold as proof that "the fold tracks its input". It proved
    # nothing of the sort: the rate loop carries integrator state, so a SECOND call
    # differs from the first REGARDLESS of input. Ticking the IDENTICAL input twice
    # also gives 1348 -> 2000. A build that ignored its input entirely would have
    # passed that control.
    #
    # Two things were wrong and both are fixed:
    #   (1) the control now uses a FRESH INSTANCE, so state cannot masquerade as
    #       input sensitivity;
    #   (2) the perturbation is one that DEMONSTRABLY moves the fold on a fresh
    #       instance. wx +0.05 does NOT — this operating point is mixer-SATURATED
    #       (m1=m2=0, m4=1), which absorbs small moves. wy +0.05 does (1348 -> 1663).
    store2 = Store()
    inst2 = Instance(store2, Module.from_file(store2.engine, MODULE), [])
    ex2 = inst2.exports(store2)
    mem2 = ex2["memory"]
    argp2 = (ex2["__heap_base"].value(store2) + 0xF) & ~0xF
    pert = list(VEHICLE_STATE)
    pert[11] += 0.05                                   # wy, an axis the fold responds to
    mem2.write(store2, struct.pack("<14f", *pert) + struct.pack("<4f", *RATE_SETPOINT), argp2)
    tp2 = ex2["pulseengine:falcon-cascade/rate@0.7.0#tick"](store2, argp2)
    t2 = struct.unpack("<4f", mem2.read(store2, tp2, tp2 + 16))
    p2 = ex2["pulseengine:falcon-cascade/mixer@0.7.0#mix"](store2, *t2)
    pwm2 = struct.unpack("<4f", mem2.read(store2, p2, p2 + 16))
    a2 = struct.unpack("<f", struct.pack("<f", sum(pwm2)))[0]
    f2 = struct.unpack("<I", struct.pack("<f", a2))[0] & 0x7FFFFFFF
    print(f"  negative control (FRESH instance, wy +0.05): {f2}"
          f"   {'DISTINCT — the fold tracks its input' if f2 != folded else 'IDENTICAL — VACUOUS'}")

    # HONEST LIMIT OF THIS ORACLE, measured rather than assumed: on a single tick from
    # a fresh instance, only wx/wy/wz and the ry/rz setpoints move the fold at all. The
    # other 10 vehicle-state scalars — the whole quaternion, position and velocity —
    # are INERT even at +-5.0, because the mixer saturates. So this differential cannot
    # detect a miscompile confined to attitude/position/velocity handling. It covers the
    # rate->mixer path and the composition plumbing, and nothing else.
    print("  oracle scope: 4 of 18 input scalars move the fold (wx, wy, wz, sp.ry/rz);")
    print("                the quaternion, position and velocity fields are INERT here.")
    return 0 if f2 != folded else 1


if __name__ == "__main__":
    sys.exit(main())
