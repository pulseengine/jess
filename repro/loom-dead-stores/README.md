# loom `dead-stores` miscompiles the meld-fused falcon core

loom's `dead-stores` pass produces a structurally-valid but **behaviorally wrong**
optimization of the meld-fused falcon flight core — it eliminates a live float
store, corrupting the control result. wasm-tools validates the output; kiln shows
the wrong value.

## Artifact
- `falcon-v1.59.fused.wasm` — sha256 `fca83e85278b4ad59e4541f78ee6d7b995ce242ed2a6f44b84a75a21245c8794`
- Built: falcon-flight-v1.59.wasm (relay release) → meld v0.31.0 fuse.

## Reproduce (loom v1.1.13, kiln v0.3.2)
```
# correct: every pass EXCEPT dead-stores
loom optimize falcon-v1.59.fused.wasm --passes dead-stores -o bad.wasm
wasm-tools validate bad.wasm        # VALID
kilnd --wasi --function run-stabilization --fuel 2000000000 bad.wasm
#   → F32 1051232186 = 0.32916  (WRONG; reference is 0.023399856)

kilnd ... falcon-v1.59.fused.wasm   # → F32 1019195662 = 0.023399856 (correct)
```
Pass-bisected: only `dead-stores` is wrong; all 15 other passes are correct.
