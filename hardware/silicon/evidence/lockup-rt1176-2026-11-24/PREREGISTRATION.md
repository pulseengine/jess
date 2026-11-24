# Lockup diagnosis, pre-registration (owner 2026-11-24: find the reset first)

## Measured before this file was written (attempt 1, `a1-no-primask.txt`)

The procedure was B2's: halt PX4, load `ekf.elf` to RAM, set VTOR=0, set sp and pc, resume. In addition, `SRC_SRSR` (0x40C04010, W1C) was cleared before the load. Bit names are from NXP's `MIMXRT1176_cm7.h`, mcux-sdk main, sha256 `d9256970…`.

| point | SRSR | meaning |
|---|---|---|
| before the clear | 0x18010007 | accumulated history; neither PX4 nor nRST clears it |
| after the clear | 0x00000000 | |
| after resume, first poll (≤ 50 ms) and all 60 polls | **0x10000004** | `M7_LOCKUP_M7` and `M7_LOCKUP_M4`: the M7 locked up and the SRC reset both cores |
| after the nRST restore | 0x10010005 | the pin-reset bits on top |

So B2's "external reset detected" is an **M7 lockup reset**. It is not a watchdog, not nRST, and not the M4.

## Hypothesis

The image's vector table (`boot-ekf.S`, section `.vectors`) has 2 words: the initial SP and the reset vector. With VTOR=0, every other vector is read from the code that follows at 0x8. PX4 is halted, not reset, so an interrupt it left enabled (SysTick, peripheral IRQs) can be pending at resume. It then vectors to an address made of code bytes and faults. The HardFault vector is code bytes as well, so the fault escalates to lockup. Renode has no such interrupt pending, which would explain why the image always completes there.

## The one variable

`reg primask 1` before `resume`. Nothing else changes: same image (`ekf.elf`, sha256 `28d297f3…`), same script apart from that one command, same gate, same claims, same restore. PRIMASK=1 masks every exception with configurable priority, which covers SysTick and all IRQs. It does not mask NMI or HardFault. The image uses no interrupts.

## Prediction and kill criterion

The run is 10 attempts.

| outcome | reading |
|---|---|
| ≥ 9 of 10 complete (sentinel and the expected words), SRSR stays 0 after resume | the hypothesis holds: a pending PX4 interrupt plus the 2-word vector table causes the lockup |
| ≤ 2 of 10 complete, or SRSR shows `M7_LOCKUP` with PRIMASK=1 | refuted: the lockup does not come from a maskable interrupt |
| 3 to 8 | inconclusive, reported as such |
| any wrong word | stops the run |

If the hypothesis holds, the fix belongs in the images, not in the loader: a full vector table whose handlers park a fault code. That is a separate change, with its own Renode and silicon evidence.
