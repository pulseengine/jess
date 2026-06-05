# kiln#270 repro — falcon `run-position-hold` never terminates on kilnd

**Artifact:** `falcon.fused.wasm` — the meld-fused falcon flight core
(built from relay source @ `f102918`). sha256 below.

## Rebuild the artifact
```
(cd relay/wasm/cm/flight && cargo component build --release)
meld fuse target/wasm32-wasip1/release/falcon_flight_component.wasm -o falcon.fused.wasm
```

## Reproduce
```
kilnd falcon.fused.wasm --function run-stabilization        # OK: 0.0233998559, Fuel consumed: 8081
kilnd falcon.fused.wasm --function run-position-hold        # HANGS 99% CPU, never returns
kilnd falcon.fused.wasm --function run-position-hold --fuel 100000   # did NOT stop (fuel bug)
# reference: wasmtime run --invoke 'run-position-hold()' falcon-flight.wasm  ->  0.1317415  (instant)
```
Same module, two exports: `run-stabilization` terminates, `run-position-hold` does not.
sha256: d07c0f06527e6ab85a173d2d9289b65a755c9056187e784d4a20967c604260a4
