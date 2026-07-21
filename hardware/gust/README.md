# Gust F100 failsafe — byte-exact pass-through oracle (REQ-PIX-004 PART-P02 (a))

The gust failsafe on the **F100 (STM32F100, Cortex-M3, soft-float)** forwards the M7's
per-motor commands **byte-exact** — no re-mixing, no per-motor floors. This is the
load-bearing PART-P02 safety property: a rank-3 rotor-out set with motors asymmetrically
**zeroed** must survive un-re-mixed, or the re-mix reintroduces the parasitic moment that
caused the relay **v1.114** failure.

## The oracle (`tools/gust/passthrough-oracle.sh`, exits non-zero on failure)
- **Positive:** `passthrough.wat` reproduces **every** row of relay's real conformance
  fixture byte-exact (184/184 checks = 46 rows × 4 motors).
- **Negative control (teeth):** `remix-negative.wat` (a symmetric averaging re-mix) MUST
  **diverge** on every row that has an asymmetric zero (23/23) — so a re-mix regression
  cannot slip through the check.

```
tools/gust/passthrough-oracle.sh
→ GUST PASS-THROUGH OK — 184/184 byte-exact vs relay's PART-P02 fixture;
  re-mix diverges on all 23 asymmetric-zero rows (negative control has teeth).
```

## On-target
`passthrough.wat` is FPU-free (it copies the i32 bit pattern; no float op, no rounding),
so it lowers with **0 skips on all three core ISAs** — `cortex-m3` (F100, 466 B),
`cortex-m4`, `cortex-m7dp` — via `synth compile -t <isa> --relocatable --native-pointer-abi`.
(Contrast the falcon flight core, still 16 skips on M7 — AFD-035/synth#782.) The gust
failsafe pass-through is therefore on-target-ready now.

## Fixture provenance
`fixtures/f100-passthrough-v1.csv` is **vendored from relay**, not authored here:
- Source: `pulseengine/relay` @ tag **`falcon-v1.124.0`**, path
  `bench-evidence/fixtures/f100-passthrough-v1.csv`.
- sha256 (vendored copy): `2306d046…`. relay drift-gates it in their CI against the real
  mixer; regeneration is coordinated on jess#144. 46 rows: 10 hover / 24 rotor_out / 12 saturated.
- Format: `phase,m0_bits,m1_bits,m2_bits,m3_bits` — f32 bit patterns (hex); expected F100
  output == input, byte-exact.

## Next rungs
1. Run `passthrough` on the **F100/M3 in Renode** per-row (execution oracle, above this
   host-level property check — the tcb-link Rung-1→Rung-2 pattern).
2. Swap the reference `passthrough` for **relay's real gust image** when it ships, keeping
   this fixture as the conformance gate.
