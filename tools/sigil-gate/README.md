# Sigil attestation gate (TEST-PIX-029 — DD-023 terminal FIRST-FLASH rung)

Proves the meld-fused falcon core can be **signed and verified with sigil (`wsc`)** — the
"sigil-signed flashable set" step of the v1.0.0 FIRST-FLASH milestone.

```
tools/sigil-gate/run.sh [falcon-vX.Y.Z | /path/to.wasm]
→ keygen: public-key 33 bytes, secret-key 65 bytes
→ sign: detached signature 108 bytes
→ verify(genuine): true
→ verify(tampered, 1 byte flipped): false
→ SIGIL OK — fused core signed + verified; tamper detected (negative control has teeth).
```

## How it works
sigil's `wsc` native binary ships **linux-only**, and `wsc-component.wasm` is a
library-world component (exports `wasm-signatures:wasmsign/signing@0.2.6`, imports WASI
0.2.4 — no `wasi:cli/run`). So jess drives it through a **wasmtime component host**
(`sigil-run/`, the scry-run pattern but component-model): `keygen → sign → verify`, plus a
**negative control** — a 1-byte-tampered core must verify `false`, so the signature
genuinely binds the bytes.

The signed input is the **path-independent reproducible** fused core (`meld fuse
--reproducible`, meld#341/AFD-034) — so the attestation is over a portable digest, the same
on any machine.

## Why it's possible now
- **sigil#164** (wsc couldn't sign its own wasip2 output) is **CLOSED**.
- The fused core is **path-independent-reproducible** (the prerequisite for a portable
  attestation key), gated by TEST-PIX-026.

## Pieces
- `wsc-component.wasm` — sigil v0.9.3 signer component (vendored).
- `sigil-run/` — the wasmtime component host driver (Rust; `wasmtime` + `wasmtime-wasi`).
- `run.sh` — fetch falcon → `meld fuse --reproducible` → `sigil-run` sign+verify. CI gate
  (a step of the `scry-gate` job).

## Next rung
Sign the full **3-image FIRST-FLASH set** (M7 falcon / M4 estimator / F100 gust) once
falcon lowers on-target (AFD-035, 14 skips remain on M7).
