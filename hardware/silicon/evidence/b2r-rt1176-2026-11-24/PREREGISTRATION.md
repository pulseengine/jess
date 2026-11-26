# B2r pre-registration: R0 repeatable on silicon with the lockup fix (TEST-PIX-039, rerun)

Committed before any B2r run. The owner authorised this campaign on 2026-11-24, to run after the loader fix merges.

## What changed since B2, and nothing else

B2 (2026-11-22, `../b2-rt1176-2026-11-22/`) recorded FAIL: 2 of 60 attempts completed. The lockup diagnosis (`../lockup-rt1176-2026-11-24/`, #327) found that each failure was an M7 lockup (SRC_SRSR 0x10000004), and that `reg primask 1` before resume gave 10 of 10 completed and correct runs.

**The one variable:** `tools/bench/on-target-run.sh` now sets PRIMASK=1 before resume and refuses to report a result unless openocd reads primask back as 1 (#328). Everything else is held from B2:
- the images, `../b2-rt1176-2026-11-22/images/`:

| image | sha256 | role |
|---|---|---|
| `ekf.elf` | `28d297f3…5f9505` | baseline |
| `ekf_nc1.elf` | `ff82571e…634ec0` | control A, gy perturbed |
| `ekf_n15.elf` | `89e48b4f…39b346` | control B, one tick fewer |

- the expected lines, `../b2-rt1176-2026-11-22/expect/`;
- `campaign.sh`, the copy committed in B2: 20 rounds of `ekf`, `ekf_nc1`, `ekf_n15`, `ATTEMPTS=1` (no retry), each attempt with its own claim of `pixhawk-6xrt` and `mcu-link`, the disarmed gate, and `--restore`; outcomes `match` / `WRONG` (stop) / `no-run` / `refused` (stop);
- `RUNFOR_MS=3000`.

The loader copied to the probe host must equal `tools/bench/on-target-run.sh` at #328's merge commit. Its sha256 is recorded in `run-1/LOADER.sha256` before the first attempt.

## Prediction

From 10 of 10 in the diagnosis:
- each image completes at least 19 of 20 attempts;
- zero `WRONG`;
- no attempt log shows `external reset detected`.

**Kill criterion for the fix:** any attempt that resets with PRIMASK read back as 1 refutes "PRIMASK=1 removes the lockup". It is reported as such, not retried away.

## Pass criteria (TEST-PIX-039, unchanged from B2)

1. At least 10 of 20 attempts complete for each image.
2. Zero `WRONG` outcomes.
3. At least 3 completed rounds are judged by `run-ekf-oracle.sh` with `WORDS_DIR=` (that round's three captures) and `ELF_DIR=../b2-rt1176-2026-11-22/images`, and the oracle exits 0. A round counts only if all three of its images matched. The oracle used is the one that judges control B at N=15. If that change has not merged when the campaign ends, criterion 3 is reported as pending, and r0 is not called passed.

A completion rate under 50% for any image means load-to-RAM is still not a base for B4, and r0 is recorded as FAIL again.

## If the gate refuses

The campaign stops. The board is left alone until the owner is back, and nothing is retried overnight.
