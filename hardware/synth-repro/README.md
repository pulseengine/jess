# synth reproducers filed from jess's on-target campaign

Minimal, self-contained `.wat` fixtures for synth defects that jess hit against the
**real falcon op-mix** and that synth could not reproduce independently. Each comes
with a negative control, because a reproducer without one does not establish that it
isolates the mechanism it claims to.

## `gi-fpu-002-phase1.wat` — VFP S-register-file exhaustion (synth#1069)

Filed because the synth maintainer tried to reproduce phase-1 exhaustion and **failed**
(*"my deep-f32 expression compiled fine at 60 bytes"*), and declined to dispatch a fix
against a defect neither side had a failing fixture for — correctly.

**The mechanism is simultaneous LIVENESS, not expression DEPTH.** A deep but sequential
f32 chain evaluates in two registers and compiles fine. What exhausts `S0..S15` is N
values that must all be live *at the same time*: each computed from the parameter (so
none is constant-folded), then all consumed in one expression tree.

| fixture | live f32 values | synth 0.55.0 `-t cortex-m7dp` |
|---|---|---|
| `gi-fpu-002-phase1.wat` | 14 | **fails** — `GI-FPU-002` |
| `gi-fpu-002-phase1-negative.wat` | 13 | compiles |

The boundary is 13→14 (not 16), implying two of `S0..S15` are otherwise committed.

The emitted error is **character-identical** to the real falcon cascade failure on
`pulseengine:falcon-cascade/attitude@0.7.0#tick` and `.../ekf@0.7.0#estimate`:

```
GI-FPU-002: VFP register file exhausted (S0..S15 all live) — f32 expression too deep for phase 1
```

Reproduce:

```sh
synth compile gi-fpu-002-phase1.wat          --relocatable -t cortex-m7dp -o /dev/null   # fails
synth compile gi-fpu-002-phase1-negative.wat --relocatable -t cortex-m7dp -o /dev/null   # compiles
```

## `gi-fpu-002-stack80.wat` — the discriminating variant (operand stack, not locals)

Built after the synth maintainer used `gi-fpu-002-phase1.wat` to run a discriminating
experiment: hold the same pressure on the **operand stack** instead of in homed locals.

| held in | count | synth 0.59.0 `-t cortex-m7dp` |
|---|---|---|
| locals | 13 | ok |
| locals | **14** | **EXHAUSTED** |
| operand stack | 60 | ok |
| operand stack | **80** | **ok** (jess extended; no wall found) |

The locals boundary is **13→14 identically on `cortex-m7dp`, `cortex-m7` and `cortex-m4f`**,
and 80-deep stack compiles on all of them.

**80 versus 14 on the same target, same element type, same arithmetic.** A register-file
*capacity* limit cannot produce a 6× gap between two ways of holding the same number of live
f32 values. The #881 spill guard's documented scope is straight-line-segment **stack** values;
homed f32 locals fall outside it, so the wall sits at 13 regardless of stack headroom.

This retired the pool-extension option in synth's own increment-2 brief: extending into
`S16..S31` would move the wall 13 → ~29 and pay prologue/epilogue cost on every affected
function, where teaching the existing guard to spill homed locals removes it on a path already
demonstrated to 80.
