@ jess RT1176 silicon bring-up payload #1 — the mechanism test.
@ Loaded into RAM by `blhost write-memory`, invoked by `blhost call <addr> <arg>`.
@ blhost `call` passes <arg> in R0 and RETURNS to the ROM bootloader afterwards,
@ so this must be a normal thumb function that ends in `bx lr` (NOT a spin loop).
@ Contract: R0 = address to write. Writes a signature + a computed value, returns.
@ Observable purely over USB via `blhost read-memory` — no UART, no probe needed.
    .syntax unified
    .cpu cortex-m7
    .thumb
    .section .text
    .thumb_func
    .global _start
_start:
    ldr   r1, =0x1E55F00D        @ "JESS FOOD" — a signature the ROM would never write
    str   r1, [r0, #0]
    add   r2, r0, #0x55          @ a value COMPUTED from the argument, so a stale
    str   r2, [r0, #4]           @ RAM read can't masquerade as a successful run
    bx    lr                     @ return to the ROM bootloader
