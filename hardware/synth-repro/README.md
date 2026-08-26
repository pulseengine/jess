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
