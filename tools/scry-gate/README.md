# scry sound-analysis gate (REQ-PIX-018 leg b)

The **DO-333 sound-static-analysis leg of the V**, run in jess CI on the
*consumed* falcon wasm. jess consumes the released, **stripped** falcon
component (no DWARF), so it cannot run relay's source-level DWARF-correlated
MC/DC gate — instead it gates the fused core with [scry](https://github.com/pulseengine/scry)'s
sound abstract interpretation. This **complements** relay's source-level MC/DC,
it does not duplicate it (deviation recorded at hub `pulseengine.eu#98`).

## What it does

```
fetch pinned falcon component  ->  meld fuse (component -> Core module)
   ->  scry-sai-core analyze()  ->  assert soundness invariants
```

`scry-run` (`scry-run/`) is a ~90-line host driver over the `scry-sai-core`
crate (the same native lib synth-cli consumes for its #383 shadow-stack
analysis). It emits a compact JSON verdict; `run.sh` asserts the gate.

## The gate (exits non-zero on any)

1. `scry-run` exits non-zero — scry could **not** soundly analyze the core.
2. `call_edges_unsound_fallback > 0` — a call site lost soundness (dropped to ⊤).
3. `diag_unsound_fallback > 0` — any `unsoundness-fallback` diagnostic.

i.e. the gate proves scry can carry a **fully sound** analysis over the whole
fused falcon core with **zero** silent unsound fallbacks — including every
`call_indirect` edge resolved soundly.

## Run

```sh
tools/scry-gate/run.sh                    # pinned falcon-v1.112.0
tools/scry-gate/run.sh falcon-v1.113.0    # a specific release
tools/scry-gate/run.sh /path/core.wasm    # a local fused core
```

## Why the baseline omits sha/bytes

`baseline.json` records the **stable soundness invariants** as evidence, not the
fused-module hash: **meld fusion is byte-nondeterministic** (identical input →
different sha256 each run). The gate therefore keys on the invariants, which are
stable across both meld runs and falcon versions. (Friction filed upstream to
meld.)

## Not covered here — the witness leg (REQ-PIX-018 leg a)

The witness branch-coverage gate is the *other* leg of REQ-PIX-018 and is **not**
wired yet: `witness run` cannot execute the multi-core fused component directly
(19 unsatisfied WASI/host imports), so it needs a counter-snapshot harness
bridge **or** an upstream single-core wasip2 falcon from relay. That remains the
pinned follow-on; this gate delivers the sound-analysis leg unilaterally.
