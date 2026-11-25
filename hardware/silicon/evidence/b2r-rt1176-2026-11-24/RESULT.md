# B2r result: r0 is repeatable on silicon with the lockup fix (TEST-PIX-039, all three criteria met)

Pre-registered in 4044e8a before any run. The loader sha256 was recorded in 25ca0aa before the first attempt. The board is the real Pixhawk 6X-RT (RT1176 M7). Every image was loaded to RAM over SWD; nothing was written to flash.

## The one variable

`tools/bench/on-target-run.sh` at #328's merge commit (00d90b5) sets PRIMASK=1 before resume and refuses to report unless openocd reads it back as 1. The images, expected lines and `campaign.sh` are B2's, unchanged. All 8 campaign files on the probe host were hash-equal to the repo before the run (`run-1/LOADER.sha256`).

## Outcome

| image | attempts | match | WRONG | no-run | refused |
|---|---|---|---|---|---|
| `ekf.elf` | 20 | 20 | 0 | 0 | 0 |
| `ekf_nc1.elf` | 20 | 20 | 0 | 0 | 0 |
| `ekf_n15.elf` | 20 | 20 | 0 | 0 | 0 |

- 0 of 60 attempt logs contain `external reset detected`. B2 had 73 of 75.
- The run lasted 2026-11-24T22:28:52Z to 22:59:24Z (`run-1/attempts.tsv`).
- Each `match` means all 31 words equal `expect/<image>.words`. For `ekf_n15` that line is the wasmtime prediction committed before B2: fold 0x4A3FE1A4, trip count 15.

## Criteria (TEST-PIX-039)

1. **At least 10 of 20 complete per image:** 20, 20 and 20. MET.
2. **Zero WRONG:** 0. MET.
3. **At least 3 rounds judged by the oracle, exit 0:** all 20 rounds were judged. The oracle was `run-ekf-oracle.sh` at e950706 (#329, control B judged in full against wasmtime at N=15). Each round was judged with `WORDS_DIR=` set to its three captures and `ELF_DIR=../b2-rt1176-2026-11-22/images`, and all 20 exited 0. MET.
   - Negative control, in exactly that setup: round 1's `ekf.words` with one tick-16 word XOR 1 exits 1, with `tick 16 state does NOT match the wasmtime reference`.
   - Per-round results are in `judge.tsv`, and the logs in `judge/`.

The prediction (at least 19 of 20 per image, no lockup resets) held. The kill criterion (any reset while PRIMASK reads back as 1) did not fire.

## What this does and does not establish

- **It does establish** that the falcon estimator image and both controls run to completion on the real RT1176 60 of 60 times by load-to-RAM. Every completion matches wasmtime bit for bit at tick 1, at tick N and in the fold. Load-to-RAM with PRIMASK=1 is therefore a usable base for B4.
- **It does not establish:**
  - which interrupt was pending at resume. PRIMASK masks them all; NVIC was not read.
  - anything about a flashed or interrupt-driven image. The image runs with interrupts masked from reset to the sentinel.
  - independence of the reference. Both sides run the same `c.loom.wasm`, so this covers synth's lowering only.
- B2's FAIL (`../b2-rt1176-2026-11-22/RESULT.md`) stays as its own record. TEST-PIX-039 stays `draft` until a fresh-context review re-derives this result from the evidence.
