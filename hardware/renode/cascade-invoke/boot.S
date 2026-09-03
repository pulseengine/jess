@ TEST-PIX-032 — invoke a falcon cascade stage on emulated RT1176 Cortex-M7.
@
@ AFD-056 established that the SELF-CONTAINED image never enters a stage: it inits and
@ spins. This harness exists to actually CALL one. It follows the DD-018 tcb-link pattern
@ (custom boot + synth --relocatable object), which is the only path in this repo that has
@ ever executed synth output on ARM.
@
@ THE EMBEDDER REGISTER CONTRACT is not guessed. It was read off synth's OWN generated
@ reset handler and confirmed at runtime in Renode (AFD-056):
@     fp (r11) = linear memory base        sl (r10) = linear memory size
@     r9       = globals table base
@ synth#1131 asks synth to confirm this is the contract rather than an artifact of the
@ self-contained path. The result below is what makes the reading falsifiable: a wrong
@ base produces garbage, not relay's SIL torque to the last bit.
    .syntax unified
    .cpu cortex-m7
    .fpu fpv5-d16
    .thumb

    .equ LINMEM,  0x20000000        @ fp — linear memory base
    .equ LINSIZE, 0x00010000        @ sl — linear memory size
    .equ GLOBALS, 0x20010100        @ r9 — globals table base
    .equ ARGOFF,  0x0000E000        @ scratch, above the data top (0xd161), below linmem end
    .equ RESULT,  0x20011000        @ torque, from the SINGLE rate#tick of the chain
    .equ CHAIN,   0x20011100        @ motor-pwm, from the mixer fed by that same call        @ where the harness parks observables for the oracle

    .section .vectors, "a"
    .word _stack_top
    .word _reset + 1

    .text
    .global _reset
    .thumb_func
_reset:
    ldr   sp, =_stack_top

    @ FPU on — a cortex-m7dp hard-float image faults on the first VFP op without this.
    ldr   r0, =0xE000ED88
    ldr   r1, [r0]
    orr   r1, r1, #0x00F00000
    str   r1, [r0]
    dsb
    isb

    @ The two instantiation promises (AFD-051), applied from the tables extracted from
    @ THIS module. jess_init() copies the 13 data segments and seeds the 12 R9 globals.
    bl    jess_init

    @ Establish the embedder registers AFTER init, before any export runs.
    ldr   r9,  =GLOBALS
    ldr   r10, =LINSIZE
    ldr   r11, =LINMEM

    @ r0 = the argument's WASM OFFSET. The canonical ABI for rate@0.7.0#tick is
    @ (param i32) -> (result i32): a pointer in, a pointer out, both linmem offsets.
    @ ONE rate#tick invocation, feeding mixer. NOT two calls: the cascade carries
    @ integrator state, so a second rate#tick returns a DIFFERENT torque than the first —
    @ which is precisely the statefulness that made AFD-048's negative control vacuous.
    @ jess_call_chain parks the intermediate torque itself so both stages stay observable
    @ from a single pass.
    ldr   r0, =ARGOFF
    bl    jess_call_chain

    @ r0 now holds the motor-pwm offset from mixer. Park it and the four pwm words.
    @ (jess_call_chain has already parked the intermediate torque at RESULT.)
    ldr   r1, =CHAIN
    str   r0, [r1]                  @ [CHAIN+0]  = motor-pwm offset
    add   r2, r11, r0               @ ARM address = linmem base + offset
    ldr   r3, [r2, #0]
    str   r3, [r1, #4]              @ [CHAIN+4]  = m1
    ldr   r3, [r2, #4]
    str   r3, [r1, #8]              @ [CHAIN+8]  = m2
    ldr   r3, [r2, #8]
    str   r3, [r1, #12]             @ [CHAIN+12] = m3
    ldr   r3, [r2, #12]
    str   r3, [r1, #16]             @ [CHAIN+16] = m4
    ldr   r3, =0x1E55D09E
    str   r3, [r1, #20]             @ [RESULT+20] = a completion sentinel

1:  b     1b
