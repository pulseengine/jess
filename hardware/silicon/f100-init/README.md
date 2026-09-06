# The embedder-init promises, discharged on real STM32F100 silicon

AFD-046 lowered the full falcon cascade for Cortex-M by passing synth two flags:

    --embedder-data-init     (synth #1041)   memory 0's active data segments
    --embedder-global-init   (synth #1052)   the R9 globals table

Those flags emit **byte-identical code**: they convert a refusal into an acknowledgement
that the *embedder* owes the state, and nothing else.

> **Correction.** The first version of this README (and of AFD-107, PR #251 and its commit
> message) said the tables were emitted and *"nothing anywhere consumed them"*. That was
> **false**, and clean-room verification caught it. `hardware/renode/cascade-invoke/harness.c`
> has applied both tables since AFD-051; `boot.S` calls it; TEST-PIX-032 runs it under Renode
> as a required CI step, complete with an NC2 control that skips the init. The retraction is
> kept here rather than edited away.

**What this directory adds** is narrower and still worth having:

1. **The apply loop had only ever executed under Renode.** In this campaign that distinction
   is load-bearing: AFD-088 found the Renode M3 platform sized to 256 KB against a real 8 KB
   part for six weeks, so "it ran in Renode" is precisely the evidence class that has already
   failed here once.
2. **A generic, standalone apply loop.** `harness.c`'s is welded into the Renode harness at
   fixed addresses; `apply_init.c` is a translation unit any embedder can link — and it is the
   one CI now *executes* against the cascade's real tables.

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

## What CI does and does not cover

CI (`on-target-oracles`) gates: the parser self-test with its must-refuse control; the image
built **on the campaign pin** under `verify-embedder` plus its negative control; the apply loop
**executed** against the cascade's real tables and compared to wasmtime's instantiated memory,
with a gutted-loop negative control; and a non-empty-tables assertion.

**CI cannot run the silicon leg** — a hosted runner has no ST-Link. That leg is hand-run against
this bench, and this README is its record. An earlier version of the CI comment pointed here for
that gap while this file said nothing about CI at all; that is what this section fixes.

An earlier CI step checked only that `apply_init.c` **linked** against the cascade tables. A
clean-room verifier gutted the loop body to `return;` and the step still passed — it gated
linkability, not consumption. Hence the executed check above.

## Scope — what this does and does not claim

- **Does:** the apply loop EXECUTED on real silicon, on a Cortex-M3, and the applying
  was observed to change the answer.
- **Does not:** this is not the falcon cascade on silicon, and not the RT1176. The cascade's
  own tables (13 segments / 43,005 B / 12 globals) compile for `cortex-m4f` and link against the
  same generic loop with 0 undefined — **but only with libgcc linked in**; the cascade object
  alone still leaves `__aeabi_f2lz` / `__aeabi_l2f` / `__aeabi_ul2f`, the known AFD-046
  obligation. The loop *is* executed against those tables on the CI host, which is more than
  "links" — but it is not silicon. No falcon code has executed on an RT1176; the debug adapter
  is in transit.

## Reproducibility and recovery

The flashed image is **byte-identical whether built with the campaign pin (synth 0.60.0)
or 0.63.0** (`md5 44cbc79c49735d1a616eec6b34a6cdd3`), so the silicon result is not an
artifact of an off-pin toolchain.

The board's resident firmware is restored from
`~/bench/f100-backup/original-flash.bin` (131072 B,
sha256 `10969f5c35de715696c377c2ae367b9be5950698115f3f91adf479bb12a0a78b`); read-back was
demonstrated byte-identical in AFD-091.

`run-on-silicon.sh` **verifies that hash and refuses to flash if it does not match**. An earlier
version of this sentence claimed the re-check as an existing property while the hash lived only
in a comment and nothing executed it — found by clean-room verification. It is now a real
precondition, and the run prints the verified hash before writing.

`run-on-silicon.sh` self-claims the probe through `with-device` (gale drives the same
ST-Link) rather than trusting the caller to hold a claim.
