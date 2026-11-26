# Vector-table run: result so far (STOPPED by the pre-registered stop rule)

Pre-registration: `PREREGISTRATION.md`, commit b572573, pushed before any attempt. Loader and the 10 staged files were hash-equal to that commit on the probe host (`run-P/LOADER.sha256`).

## Arm P (new table, PRIMASK=1): 5 attempts, then stopped

| round | outcome | reset | exception log |
|---|---|---|---|
| 1–5 | match (31 of 31 words equal `expect/ekf.words`) | none | 0 exceptions taken |
| 6 | **refused before load** | — | — |

All 5 loaded attempts halted at PC 0x4b2 (the spin loop after `_reset` at 0x484) and PX4 came back after the nRST restore (~10 s each).

Round 6: the campaign's `wait_app` saw the PX4 app enumerated for 5 s, then the disarmed gate failed to read the console with `(5, 'Input/output error')` and refused. A read-only check 10 s later showed `PX4 BL FMU v6XRT.x`. From 08:02:25 UTC onwards, 4 checks at 25 s intervals showed the app (`PX4 FMU v6XRT.x`) and its console present. Nothing was loaded in round 6. This is the gate refusing on a re-enumeration, the same EIO class B2 recorded on 2026-11-22. It is not a result about the image.

## Not run

Arm V (the test) and arm C (the control) were **not run**. The pre-registration says a gate refusal stops the run and the board is left for the owner. Resuming is the owner's decision.

## What this shows so far

The new image with the production loader completed 5 of 5 and matched, with 0 exceptions. The question the run exists to answer, whether a full table survives a pending interrupt with PRIMASK=0, is **unanswered**.
