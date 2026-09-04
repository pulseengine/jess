#!/usr/bin/env python3
"""SIL reference for the falcon rate loop — the number the LOWERED ARM must match.

Runs the SAME fused core module that synth lowers, in wasmtime. That is the point:
one module, two backends. Any divergence is a lowering defect, not a modelling
difference — which is exactly what jess owes under DD-026 P2 (relay proves the loop
closes in source; jess proves it still closes after lowering).

Canonical ABI of the export, from the WIT + the lowered signature:
    rate@0.7.0#tick : (param i32) -> (result i32)
    arg  ptr -> vehicle-state (14 x f32, 56 B) followed by rate-setpoint (4 x f32, 16 B)
    ret  ptr -> torque-setpoint (4 x f32, 16 B)
"""
import struct, sys
from wasmtime import Store, Module, Instance

# NO DEFAULT MODULE. This used to default to .scratch/v1341/casc_new.loom.wasm — a file with
# no pin, no locator and no derivation, present only on the machine that once produced it
# (AFD-075). Defaulting to it meant this script could silently reference an artifact nobody
# else can reproduce, and report numbers from it as if they were the campaign's. Require the
# caller to name the module.
if len(sys.argv) < 2:
    sys.stderr.write(
        "usage: %s <fused-core.wasm>\n"
        "No default: the module must be one you can reproduce (see tools/deps/fetch.sh and\n"
        "tools/appcompose/build-and-verify.sh, which derives it from the pinned components).\n"
        % sys.argv[0])
    sys.exit(2)
MODULE = sys.argv[1]
EXPORT = "pulseengine:falcon-cascade/rate@0.7.0#tick"

# One deliberately non-symmetric test vector. Symmetric or all-zero inputs are a
# vacuous differential: they can be reproduced by a miscompile that drops terms.
VEHICLE_STATE = [
    1.0, 0.0, 0.0, 0.0,          # qw qx qy qz  (level attitude)
    0.0, 0.0, -2.5,              # pos n e d
    0.1, -0.2, 0.05,             # vel n e d
    0.30, -0.15, 0.07,           # wx wy wz  <- distinct body rates, all three axes
    0.0,                         # innovation
]
RATE_SETPOINT = [1.0, 0.0, 0.0, 0.5]   # 1 rad/s about x, matching relay's step test


def main():
    store = Store()
    inst = Instance(store, Module.from_file(store.engine, MODULE), [])
    mem = inst.exports(store)["memory"]
    tick = inst.exports(store)[EXPORT]

    # scratch above the module's own static data
    heap_base = inst.exports(store)["__heap_base"].value(store)
    argp = (heap_base + 0xF) & ~0xF

    buf = struct.pack("<14f", *VEHICLE_STATE) + struct.pack("<4f", *RATE_SETPOINT)
    mem.write(store, buf, argp)

    retp = tick(store, argp)
    tx, ty, tz, thrust = struct.unpack("<4f", mem.read(store, retp, retp + 16))

    print(f"  module     {MODULE}")
    print(f"  arg ptr    0x{argp:08X}   (heap_base 0x{heap_base:08X})")
    print(f"  ret ptr    0x{retp:08X}")
    print(f"  torque     tx={tx:.9g} ty={ty:.9g} tz={tz:.9g} thrust={thrust:.9g}")
    print(f"  raw hex    {' '.join(f'{w:08X}' for w in struct.unpack('<4I', mem.read(store, retp, retp+16)))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
