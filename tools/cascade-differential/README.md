# Cascade differential — SIL reference vs lowered ARM

DD-026 P2 splits the proof: **relay proves the loop closes in source (SIL); jess proves it
still closes after lowering.** This directory is jess's half. It is *not* a second simulator —
relay owns SIL. What jess needs is a **single discriminating vector** with a known-good answer,
so the lowered ARM can be checked against it.

## `sil_reference.py` — DONE

Runs the **same fused core module that synth lowers**, in wasmtime. One module, two backends:
any divergence is a lowering defect, not a modelling difference.

```
rate@0.7.0#tick : (param i32) -> (result i32)      # canonical ABI, pointer in / pointer out
  arg -> vehicle-state (14 x f32, 56 B) ++ rate-setpoint (4 x f32, 16 B)
  ret -> torque-setpoint (4 x f32, 16 B)
```

**Reference vector** (deliberately asymmetric — body rates distinct on all three axes; a
symmetric or all-zero input would be a vacuous differential, reproducible by a miscompile that
drops terms):

```
state  qw=1 qx=qy=qz=0 · pos 0,0,-2.5 · vel 0.1,-0.2,0.05 · w 0.30,-0.15,0.07 · innov 0
sp     rx=1.0 ry=0 rz=0 thrust=0.5          (1 rad/s step about x, matching relay's step test)

TORQUE tx=1  ty=0.472507507  tz=-0.147003502  thrust=0.5
hex    3F800000 3EF1EC81 BE168816 3F000000
```

`ty` and `tz` are non-obvious functions of the rate error across three axes — that is what makes
this vector discriminating rather than decorative.

## `arm_invoke_ATTEMPT.robot` — NOT WORKING, kept for the next attempt

Invoking the same export on the lowered ARM image in Renode. **What is established:**

- entry `pulseengine:falcon-cascade/rate@0.7.0#tick` at `0x7a4`
- AAPCS: **`r0` = argument pointer** (`str.w r0, [sp, #152]`), result in `r0`
- **`r9` = globals-table base**, set by the reset handler to `0x20010100` — *verified live in
  Renode*, so the export cannot be called before boot has run
- reset handler: init linear memory (53,345 B → `0x20000100`) → set `r9` → init globals →
  `blx` the first export → spin at `0x16c`
- linear-memory mapping: wasm `0x2280` → ARM `0x20002380`

**The blocker:** after `emulation RunFor` reaches the spin at `0x16c`, setting `cpu PC` to the
export entry and resuming (via `RunFor` or `cpu Step`) does not execute — PC stays at `0x7a4`
and `r0` is unchanged. Tried with and without the thumb bit. This is Renode CPU-resume plumbing,
not a falcon or lowering problem.

Next attempt should try: driving the call from the image itself (a small harness export that
calls `tick` with a fixed pointer and stores the result at a known address, so no PC redirect is
needed) — that sidesteps the resume issue entirely and is closer to how the on-target test will
have to work anyway.
