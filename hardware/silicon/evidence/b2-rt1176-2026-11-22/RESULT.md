# B2 result, 2026-11-22: r0 is NOT repeatable on silicon (fail)

Pre-registered in 7b1a231, before any run. The run is on the real Pixhawk 6X-RT, RT1176 M7, loading to RAM over SWD with nothing written to flash. The data is in `run-2/` (`attempts.tsv`, one `.log` per load, and a `.words` capture per completion).

## Outcome (60 load attempts)

| image | completed | completion criterion (≥10/20) | wrong words |
|---|---|---|---|
| `ekf` (baseline) | 1 / 20 | **fail** | 0 |
| `ekf_nc1` (control A) | 0 / 20 | **fail** | 0 |
| `ekf_n15` (replacement control B) | 1 / 20 | **fail** | 0 |

- **Criterion 1 fails for all three images.** Under the pre-registered rule, r0 is recorded as fail: load-to-RAM is not a base for B4.
- **Criterion 2 (zero wrong words) holds.** Both completions equal their expected line in all 31 words:
  - `ekf` round 15 reproduced the 2026-11-17 capture (trip 0x10, fold 0x6EC49E30).
  - `ekf_n15` round 13 matched the wasmtime prediction committed before the run (trip 0x0F, fold 0x4A3FE1A4).
- **Criterion 3** (oracle exit 0 over ≥3 judged runs per image) was not reached. No image has 3 completions, and the oracle change it needs is queued behind the CI hold.
- **Every attempt that did not complete is the same event.** 73 of the 75 load logs (60 here and 15 in `b2b/`) contain `external reset detected`, with PC 0x00223104 (PX4) afterwards and all-zero parking words. The 2 logs without it are the 2 completions.
- **Two attempts were `refused`, not loaded.** In both, the PX4 app rebooted 9 s and 14 s after enumerating, while the read-only gate was reading and before any load, so the gate got EIO. Their logs were overwritten when those rounds were re-run; `attempts.tsv` keeps the rows. The cause is unknown. In 120 s of idle observation the board did not reboot.

## Control B on silicon (AFD-153)

The replacement control B **was observed on silicon**: one completion, matching its pre-registered prediction word for word. The old control B (`ekf_nc2`) never completed on silicon. One completion shows the control can be observed. It is not a rate.

## B2b diagnostic (`b2b/`, pre-registered in 70d1bb8)

The test changed one variable, `RUNFOR_MS` from 3000 to 200, which shortens halt-to-read from about 4.1 s to about 1.3 s. **0 of 15 completed**, which is in the pre-registered "refuted" band (0–2).

A run window of ≥ 200 ms does not avoid the reset. If the reset is time-based, it arrives within about 1.3 s of the halt, which includes the 1.07 s load.

## Procedure changes made during the run (each committed before the attempts it affected)

| commit | change |
|---|---|
| 706325e | The gate reads the FMU by `/dev/serial/by-id`. `ttyACM0` had become an unrelated USB radio after the host rebooted, and run 1's "0 bytes" reading is retracted. |
| a356cf5 | Before each attempt, wait for the PX4 app by its kernel product string. The bootloader shares 3643:001d, and `lsusb` names both "PX4 FMU". |

## Not established

- The cause of the reset.
- Why the 2 completions came in rounds 13 and 15 after 35 straight failures.
- The rate on another day. 2026-11-17 saw 2 completions in 5 non-lockup attempts, but those were in-script retries starting from a different board state.
