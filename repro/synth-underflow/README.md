# synth value-stack underflow repro (falcon-v1.56 fused core)

synth's arm backend silently skips two functions because synth's *component
validator* reports a wasm value-stack underflow on a module that `wasm-tools
validate` accepts as valid. The skipped functions are absent from the ELF.

## Artifact
- `falcon-v1.56.fused.wasm` — sha256 `bd946fb594e44f2991bd16afc746eb188ee4be08046cbde072b0b8b946b29713`
- Built: falcon-flight-v1.56.wasm (relay release, sha256 3fb275db…a41341)
  → loom v1.1.13 optimize → meld v0.30.0 fuse. (Also reproduces with meld v0.29.0.)

## Reproduce
```
wasm-tools validate falcon-v1.56.fused.wasm        # VALID
synth compile falcon-v1.56.fused.wasm --cortex-m --all-exports -o out.elf
```

Observed (synth v0.11.39 and v0.11.40):
```
warning: skipping function 'func_30': ... Component validation failed:
  wasm value-stack underflow at op 21 (LocalSet(2)): would pop 1 from depth 0
warning: skipping function 'func_39': ... Component validation failed:
  wasm value-stack underflow at op 2 (Select): would pop 3 from depth 2
```
