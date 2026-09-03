@ TEST-PIX-033 — the N-TICK SOAK image.
@
@ Deliberately a SEPARATE image from boot.S. The chain image advances the cascade one tick
@ before it parks its result; appending a soak to it would offset every tick against the
@ wasmtime reference by one. Same class of error as AFD-060's double rate#tick, which the
@ reference caught rather than inspection.
@
@ Everything up to the call is byte-for-byte the boot.S prologue: FPU on, jess_init applies
@ the 13 data segments and 12 globals, then the embedder registers are established AFTER
@ init and BEFORE any export runs (synth#1131, docs/embedder-abi-relocatable-arm.md).
    .syntax unified
    .cpu cortex-m7
    .fpu fpv5-d16
    .thumb

    .equ LINMEM,  0x20000000        @ fp  (r11) — linear memory base
    .equ LINSIZE, 0x00010000        @ sl  (r10) — linear memory size
    .equ GLOBALS, 0x20010100        @ r9        — globals table base
    .equ ARGOFF,  0x0000E000        @ argument vector, as in the chain image
    .equ SOAK_N,  64                @ tick count; the oracle passes the SAME N to the reference

    .section .vectors, "a"
    .word _stack_top
    .word _reset + 1

    .text
    .global _reset
    .thumb_func
_reset:
    ldr   sp, =_stack_top

    ldr   r0, =0xE000ED88
    ldr   r1, [r0]
    orr   r1, r1, #0x00F00000
    str   r1, [r0]
    dsb
    isb

    bl    jess_init

    ldr   r9,  =GLOBALS
    ldr   r10, =LINSIZE
    ldr   r11, =LINMEM

    @ jess_call_soak(ARGOFF, SOAK_N) — parks N, tick-1 pwm, tick-N pwm, the FNV-1a fold
    @ over every tick's four pwm words, and its own sentinel, at SOAK_BASE (0x20011200).
    ldr   r0, =ARGOFF
    mov   r1, #SOAK_N
    bl    jess_call_soak

1:  b     1b
