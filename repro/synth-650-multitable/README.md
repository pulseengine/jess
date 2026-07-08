# synth#650 — multi-table call_indirect (table index ≥1) loud-declines

`table1_ci.wat` is the minimal hermetic repro for AFD-033 / synth#650: synth's
arm (thumb-2) backend links only **table 0** at R11, so `call_indirect` through
**table index 1** is refused:

```
synth compile <(wasm-tools parse table1_ci.wat) -t cortex-m7dp
→ skipping function 'via_t1': ... call_indirect: table index 1 is not supported
  (only table 0 is linked at R11) — #642
```

## Why it matters to jess

The released **falcon-flight v1.112** fused core (meld → loom) carries **two**
funcref tables — `(table 0 7 7)` + `(table 1 41 41)` — and **20 of 146**
functions dispatch through table 1. On synth v0.33.1 all 20 loud-decline, making
multi-table dispatch the **2nd-largest on-target skip class after #369** (float).

Surfaced (not caused) by the #642 fix: these were *silently* miscompiled on
≤v0.33.0. This is a correctness win that reveals a residual pole. falcon
on-target is #369-gated regardless, so no urgency — but the dispatch path must be
complete when #369 lands. Candidate to graduate into a hermetic Renode oracle
(the TEST-PIX-020/021 pattern) once synth links table 1+.

## Update 2026-07-08 (synth v0.34.0) — linking fixed, null-slot residual

synth v0.34.0 shipped multi-table linking (#650 closed) — `table1_ci.wat`'s
`via_t1` now compiles. But falcon's real table 1 is *sparsely populated*, so the
same 20 funcs now decline on a **null-funcref-slot** check. `nullslot_ci.wat` is
the minimal repro (single table, one filled slot, rest null → `call_indirect`
declines "slot is uninitialized (null funcref)"). Filed **synth#664**. falcon
inventory unchanged at 46/146 (the 20 moved from linking to null-slot lowering).
