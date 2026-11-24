# B2b pre-registration: does a shorter run window avoid the reset?

This is a diagnostic. It is **not** B2: it does not change B2's result and does not count toward TEST-PIX-039. It was committed before any B2b run, while run 2 of B2 was still in progress. At that point the count stood at 0 of 31 load attempts completed, and in all 31 logs the board reset during the run window ("external reset detected", PC 0x00223104 afterwards, all-zero parking words).

## The one variable

`RUNFOR_MS=200` replaces the default of 3000. Everything else matches B2 run 2:
- the same 3 images (`images/`);
- the same campaign.sh, with `wait_app`, both claims per attempt, the disarmed gate, `ATTEMPTS=1` and `--restore`;
- the same expected lines.

The image needs about 16 estimator calls, which takes milliseconds. 200 ms is therefore ample for it to finish if nothing resets the board.

## Hypothesis under test

Something outside the M7 core resets the board a fixed time after PX4 stops running, and the image's words are lost because the read comes about 4 s after the halt (1.07 s to load plus 3 s to run). An external watchdog serviced only by the running PX4 app is one candidate. That is a guess, not a measurement. The internal watchdogs were measured disabled (`on-target-run.sh` header).

## Prediction and its reading

The run is 5 rounds × 3 images = 15 load attempts.

| outcome | reading |
|---|---|
| 8 or more of 15 complete, all matching | the reset is time-dependent, and B2 should be re-run with the shorter window as its own pre-registered campaign |
| 0 to 2 of 15 complete | a shorter window does not help; the hypothesis is refuted for windows ≥ 200 ms |
| 3 to 7 | inconclusive; reported as such, with no conclusion drawn |
| any `WRONG` | stops the run, and outranks everything else |

The outputs go to a separate directory (`out-b2b`). They are not merged with B2's attempts.
