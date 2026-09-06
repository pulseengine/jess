# The embedder-init promises, discharged on real STM32F100 silicon

AFD-046 lowered the full falcon cascade for Cortex-M by passing synth two flags:

    --embedder-data-init     (synth #1041)   memory 0's active data segments
    --embedder-global-init   (synth #1052)   the R9 globals table

Those flags emit **byte-identical code**. They convert a refusal into an acknowledgement
that the *embedder* owes the state, and nothing else. They are promises, and until this
rung they were unkept: `tools/embedder-init/extract_init.py` emitted the tables, and
**nothing anywhere consumed them.** The pipeline stopped at *links clean* — which, per
this campaign's own rule, is not *works*.

## What runs here

`apply_init.c` is the missing half: the loop that copies the emitted segments into
linear memory and the emitted initialisers into the R9 table. It is generic over the
tables, not a fixture for this probe.

`probe.wat` exports exactly two functions, which synth lowers to exactly two loads:

    read_data    ->  ldr r0, [r11, #0x100]     the active data segment
    read_global  ->  ldr r0, [r9]              globals table slot 0

so an unkept promise is a **wrong value**, not a subtle drift.

## Result, 2026-09-07 — STM32VLDISCOVERY (STM32F100, Cortex-M3), ST-LINK/V1, `fourpi` bench

```
LEG (only the APPLY word differs)  read_data   read_global completion
  init APPLIED (baseline)          44332211    5a5a0000    c0ffee00   OK
  init SKIPPED (negative control)  deadbeef    deadbeef    c0ffee00   OK
```

`44332211` is the data segment `\11\22\33\44` read back little-endian; `5a5a0000` is the
declared global. Both are exactly the values in the emitted tables.

### Why this control is not vacuous

Three properties, each of which a previous version of some check in this repo lacked:

1. **The two legs run the BYTE-IDENTICAL flashed image.** The apply decision is a runtime
   input — one word the host writes at `0x20000480` before `resume` — not a build flag.
   Exactly one variable differs (AFD-048).
2. **Both regions are poisoned with `0xDEADBEEF` before the decision.** Without the poison,
   "init not applied" could read as an accidental zero and be indistinguishable from a
   legitimately-zero value. The failing case has to be *observable* for the passing case
   to mean anything.
3. **The completion marker `c0ffee00` is present in BOTH legs.** So the control measured
   *"init was not applied"* and **not** *"the CPU never resumed"* — which is precisely the
   confusion AFD-048 found shipped in a merged safety artifact.

## Scope — what this does and does not claim

- **Does:** the apply loop EXECUTED on real silicon, on a Cortex-M3, and the applying
  was observed to change the answer.
- **Does not:** this is not the falcon cascade, and not the RT1176. The cascade's own
  tables (13 segments / 43,005 B / 12 globals) compile for `cortex-m4f` and link clean
  against the same generic loop with 0 undefined — but that is *links*, not *runs*.
  No falcon code has executed on an RT1176; the debug adapter is still in transit.

## Reproducibility and recovery

The flashed image is **byte-identical whether built with the campaign pin (synth 0.60.0)
or 0.63.0** (`md5 44cbc79c49735d1a616eec6b34a6cdd3`), so the silicon result is not an
artifact of an off-pin toolchain.

The board's resident firmware is restored from
`~/bench/f100-backup/original-flash.bin` (131072 B,
sha256 `10969f5c35de715696c377c2ae367b9be5950698115f3f91adf479bb12a0a78b`) — the hash is
re-checked before any write, and read-back was demonstrated byte-identical in AFD-091.

`run-on-silicon.sh` self-claims the probe through `with-device` (gale drives the same
ST-Link) rather than trusting the caller to hold a claim.
