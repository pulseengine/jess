@ Minimal native TCB shim for the DD-018 --relocatable + TCB-link on-target model.
@ Proves the seam end-to-end on real ARM (Renode RT1176): the synth-compiled wasm
@ `compute` (seam.o, from seam.wat) calls the native primitive tcb_seed provided
@ HERE, and returns compute()=tcb_seed()+1. reset stores the result to DTCM so the
@ oracle can read it. This is the gale-maximal-wasm boundary: wasm code + a thin
@ native TCB, linked into one image (vs the self-contained --cortex-m path).
    .syntax unified
    .cpu cortex-m7
    .thumb

    .section .vectors, "a"
    .word _stack_top            @ 0: initial SP
    .word _reset + 1            @ 1: reset vector

    .text
    .global _reset
    .thumb_func
_reset:
    ldr   sp, =_stack_top
    bl    compute               @ call the synth-compiled wasm export (seam.o)
    ldr   r1, =0x20010000       @ result observation word (DTCM)
    str   r0, [r1]              @ store compute() so Renode can read it
1:  b     1b

    @ The native TCB primitive the wasm imports (env::tcb_seed). AAPCS: result in r0.
    .global tcb_seed
    .thumb_func
tcb_seed:
    movw  r0, #0xCAFE           @ the seed the native trusted base provides
    bx    lr
