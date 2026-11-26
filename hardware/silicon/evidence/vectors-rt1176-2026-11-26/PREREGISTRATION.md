# Vector-table run, pre-registration (owner option dialog 2026-11-26: "Vector-table fix")

Committed and pushed before any attempt in this directory. Load-to-RAM only: no flash write, no ISP, no fuse.

## Background

B2 (`../b2-rt1176-2026-11-22/`) completed 2 of 60 load-to-RAM attempts. The lockup diagnosis (`../lockup-rt1176-2026-11-24/`) read SRC_SRSR 0x10000004, an M7 lockup, and found that `reg primask 1` before resume gave 10 of 10. B2r (`../b2r-rt1176-2026-11-24/`) then gave 60 of 60 with PRIMASK=1. Its hypothesis was that a PX4 interrupt is pending at resume and the image's 2-word vector table sends it, and the fault after it, to code bytes. The diagnosis said the fix belongs in the images. This is that change and its silicon test.

## What changed

`hardware/renode/cascade-invoke/vectors.inc` gives every cascade-invoke image a 256-word table (SP, reset, and 254 entries for `jess_default_handler`). The handler records each exception in a 6-word log at 0x20011F00 that the ELF load initialises (magic 0x1E55E7C0, count, first IPSR, last IPSR, fault marker, fault PC).
- An IRQ is disabled in the NVIC and the handler returns.
- SysTick is stopped and the handler returns.
- PendSV is cleared and the handler returns.
- Any other exception records the stacked PC and parks.

`tools/bench/on-target-run.sh` changes in three ways:
- It takes the entry PC from the ELF header instead of the constant 0x8.
- It reads and reports the log.
- `PRIMASK_AT_RESUME=0` skips the lockup fix, for this run only. The default stays 1.

## Images (`images/`), built from the same objects

| image | sha256 | vector table |
|---|---|---|
| `ekf.elf` | `3c9bb09b88bf7be1c603a9297149c0b326379f8f12c3f7dcc1c445bfd2068e41` | 256 words (vectors.inc), `_reset` at 0x484 |
| `ekf_2w.elf` | `67f4b543ac25a969b1143932188551ecfa1eb411631df43f6f0c2c095f705f4c` | 2 words (main's boot-ekf.S and link.ld), `_reset` at 0x8 |

Both images link the same `harness.o`, `init.o` and `cascade_named.o`. Their `.rodata` sections are byte-identical (43,289 B). The code differs by the 132-B handler and by the address shift that follows from the table size. In Renode both produce the 31 words of `expect/ekf.words`, which is B2's expected line for `ekf`, unchanged. Both copies in `expect/` are that same line. `ekf_2w.elf` stands for the table that existed before this change, so the comparison between the two images varies only the table.

## Arms, in this order

Each attempt uses B2's procedure. Every attempt takes its own claim of `pixhawk-6xrt` and `mcu-link` and passes the disarmed gate. Each runs with `ATTEMPTS=1` (no retry), `RUNFOR_MS=3000` and `--restore`. The loader is this branch's `tools/bench/on-target-run.sh`, whose sha256 goes into `run-*/LOADER.sha256` before that arm's first attempt.

| arm | image | PRIMASK at resume | attempts | role |
|---|---|---|---|---|
| P | `ekf.elf` | 1 | 10 | the production loader with the new image: a regression check |
| V | `ekf.elf` | 0 | 10 | **the test**: interrupts enabled, so a pending interrupt reaches the new table |
| C | `ekf_2w.elf` | 0 | 5 | control: the same condition with the old table, which should reproduce B2 |

P runs first because it carries the least risk. C runs last because it is expected to lock up.

## Predictions

- **P:** 10 of 10 complete and match. 0 exceptions in every log. No `external reset detected`.
- **V:** at least 9 of 10 complete and match, and no `external reset detected`. Under the hypothesis, the log shows at least 1 exception in at least 1 attempt, each with exception number ≥ 14 (SysTick, PendSV or an IRQ). The IRQ numbers are reported.
- **C:** at most 1 of 5 completes, and the rest show `external reset detected`. That matches B2's 2 of 60 and the lockup diagnosis.

## Readings and kill criteria

| outcome | reading |
|---|---|
| V ≥ 9/10 and C ≤ 1/5, with V's logs showing exceptions ≥ 14 | the hypothesis holds and the full table fixes it: the pending interrupt now reaches a handler that exists, and the IRQ is identified |
| V ≥ 9/10 and C ≤ 1/5, but every V log shows 0 exceptions | the table fixes it, but not through a logged interrupt. The mechanism stays open and is reported as such |
| V ≤ 2/10, or any V attempt shows `external reset detected` | **refuted**: a full table does not prevent the lockup. PRIMASK=1 stays the only fix |
| V 3 to 8 of 10 | inconclusive |
| C ≥ 3/5 | the control did not reproduce B2, so V says nothing about the table. Reported as such |
| any V log shows the fault marker 0xDEADFA17 | the image faulted with interrupts enabled. The exception number and PC are recorded. The attempt counts as not completed |
| any `WRONG` | stops the arm and outranks everything above |

The default stays PRIMASK=1 whatever V shows. Changing it is a separate decision.

## Stop rules

- If the gate refuses, or PX4 does not come back after an attempt, the run stops. The board is left alone for the owner. Nothing is retried overnight, and arms not yet run are reported as not run.
- C is the arm most likely to leave the board needing a power cycle, which is why it runs last.
