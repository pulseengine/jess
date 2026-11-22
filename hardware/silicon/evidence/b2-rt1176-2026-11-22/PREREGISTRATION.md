# B2 pre-registration: R0 repeatable on silicon (TEST-PIX-039)

Committed before any B2 run. Plan: `docs/plan-v0.8.0.md` row B2.

## Images (loaded to RAM over SWD; nothing is written to flash)

| image | sha256 | role |
|---|---|---|
| `ekf.elf` | `28d297f3…5f9505` | baseline, the TEST-PIX-037 image |
| `ekf_nc1.elf` | `ff82571e…634ec0` | control A: gy perturbed, attributive (unchanged from TEST-PIX-037) |
| `ekf_n15.elf` | `89e48b4f…39b346` | **replacement control B**: trip count 15 instead of 16 |

## Replacement control B

The old control B (`ekf_nc2`, embedder init skipped) does not complete on silicon (AFD-153): one reset, one double-fault lockup. The plan requires a control that changes one variable and completes on silicon.

**The one variable.** `ekf_n15.elf` is the baseline relinked from the same objects as `ekf.elf`, with `boot-ekf.S` assembled under `--defsym EKF_N=15`.

**The bytes.** The loaded image is 84,737 B and differs from the baseline in exactly 1 byte, at offset 49, the immediate of `mov.w r0, #EKF_N`: 0x10 → 0x0F. The ELF differs in 42 bytes, which is that byte plus a non-loaded ABS symbol `EKF_N` in the symbol table.

**Instrument check, done before the prediction.**
- Relinking the default build from the same objects reproduces `28d297f3…` exactly.
- wasmtime over `c.loom.wasm` (`b35f3036…`) at N=16 gives fold 0x6EC49E30. That equals the 2026-11-17 silicon capture.

**Prediction, from wasmtime at N=15:**
- word 0 (trip count): 0x0000000F
- words 1–14 (tick 1): identical to the baseline
- words 15–28 (tick N): equal to wasmtime's tick-15 state; 10 of these 14 words differ from the baseline's tick-16 state
- word 29 (fold): **0x4A3FE1A4** (the baseline's is 0x6EC49E30)
- word 30: sentinel 0x1E55E4F0

The full expected line is in `expect/ekf_n15.words`.

**What it attributes.** The control attributes the result to the iteration count, which the oracle must observe in the trip word, the tick-N state and the fold. Control A remains the input-attributive control.

## Expected lines

| file | source |
|---|---|
| `expect/ekf.words` | the 2026-11-17 silicon capture, which matched wasmtime (tick 1, tick 16, fold) |
| `expect/ekf_nc1.words` | the 2026-11-17 silicon capture, which matched Renode word for word. It is a repeatability reference, not a wasmtime reference. |
| `expect/ekf_n15.words` | the wasmtime prediction above |

## Procedure

`campaign.sh` runs on the probe host. It makes 20 rounds; each round runs `ekf`, then `ekf_nc1`, then `ekf_n15`, which gives 60 load attempts. The rounds interleave the images so that drift over time is not confounded with the image.

Each attempt:
- holds its own claim of both `pixhawk-6xrt` and `mcu-link`;
- passes the fail-closed disarmed gate;
- runs with `ATTEMPTS=1`, so there is no retry and every load is counted once;
- ends with `--restore`.

Each attempt's outcome is one of:

| outcome | meaning | effect |
|---|---|---|
| `match` | the capture equals the expected line | counted as a completed run |
| `WRONG` | the capture differs from the expected line | stops the bet, and outranks the release |
| `no-run` | the image was loaded but there is no sentinel | counted as an attempt that did not complete |
| `refused` | the gate or the claim refused, so nothing was loaded | not a load attempt; the run stops and is resumed with `START=` |

## Pass criteria (TEST-PIX-039)

1. At least 10 of 20 attempts complete for each image.
2. Zero `WRONG` outcomes.
3. At least 3 completed runs per image are judged by `run-ekf-oracle.sh WORDS_DIR=`, and the oracle exits 0.

Criterion 3 needs an oracle change. The oracle currently reads `ekf_nc2.words` for control B, so it has to judge `ekf_n15` against wasmtime at N=15 instead. That change is a pull request, queued behind the org CI hold of 2026-11-20. Until it lands, B2 reports criteria 1 and 2 only, and r0 is not called passed.

A completion rate under 50% for any image means load-to-RAM is not a base for B4, and r0 is recorded as fail.
