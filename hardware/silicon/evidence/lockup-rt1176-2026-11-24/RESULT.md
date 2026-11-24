# Lockup diagnosis, result: the hypothesis HOLDS (10 of 10)

The test was pre-registered in aedd9ec, before the PRIMASK runs. The board is the real Pixhawk 6X-RT, RT1176 M7, loaded to RAM over SWD with nothing written to flash. The image is `ekf.elf` (`28d297f3…`).

| condition | attempts | complete and correct | SRSR after resume |
|---|---|---|---|
| B2 procedure (no PRIMASK), 2026-11-22 | 60 | 2 | not read; 73 of 75 logs show `external reset detected` |
| attempt 1 here (no PRIMASK, SRSR cleared first) | 1 | 0 | **0x10000004**, M7 lockup (`M7_LOCKUP_M7` and `M7_LOCKUP_M4`), from the first 50 ms poll on |
| **`reg primask 1` before resume, the one variable** | **10** | **10** | **0x00000000** in all 60 polls of every attempt |

Every PRIMASK attempt returned fold 0x6EC49E30 and sentinel 0x1E55E4F0, which equal the 2026-11-17 capture and the wasmtime reference. No attempt was refused. `b-primask-summary.txt` has one line per attempt, and `b-primask-a<N>.txt` holds each full log.

## What this establishes

B2's intermittent "external reset" is an **M7 lockup reset**. Masking the maskable exceptions removes it completely (0 of 10 lockups, against 59 of 61 without the mask). The mechanism is consistent with the pre-registered one:
- PX4 is halted, not reset, so an interrupt it enabled can be pending at resume.
- The jess image's vector table has 2 words, so the vector for that interrupt is read from code bytes.
- The fault that follows has no valid HardFault vector either, so it escalates to lockup.

## What it does not establish

- **Which interrupt.** PRIMASK masks them all. Reading NVIC ISPR/ICSR at resume would identify it; that is not done here.
- **That the mechanism is exactly the vector table.** The masking result fits it. A direct test is an image with a full vector table whose handlers park a fault code, run without PRIMASK.

## Consequence for B2 and B4

Load-to-RAM is a usable base once maskable interrupts are off before resume. There are two fixes, and they do not exclude each other:
- in the loader, `reg primask 1` in `on-target-run.sh`, a one-line change;
- in the images, a full vector table with parking handlers, which also turns any future fault into a captured code instead of a reset.

B2 needs a fresh pre-registered campaign under the fix to report r0. This result does not change B2's recorded FAIL.
