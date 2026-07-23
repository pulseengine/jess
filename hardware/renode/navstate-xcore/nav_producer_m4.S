@ NavState producer (M4 estimator core, FPv4-SP) for the inter-core crossing oracle
@ (REQ-PIX-007, TEST-PIX-030). Writes the 16-word (64 B) NavState message to the
@ M7<->M4 SHMEM ring @0x20400000, then publishes a READY flag @0x20400040 LAST so the
@ consumer only reads a fully-written message (flag-last release order). Vectors/text
@ in OCRAM @0x20240000 (shared RT1176 sysbus). Pattern word[i]=0x4E560000+i (distinct,
@ "NV"+i) — the oracle asserts the M7 side reproduces it byte-exact.
    .syntax unified
    .cpu cortex-m4
    .thumb
    .section .vectors, "a"
    .word _m4_stack_top
    .word reset + 1
    .text
    .thumb_func
    .global reset
reset:
    ldr   sp, =_m4_stack_top
    ldr   r0, =0x20400000        @ SHMEM NavState base
    movw  r1, #0x0000
    movt  r1, #0x4E56            @ r1 = 0x4E560000
    movs  r2, #16
1:  str   r1, [r0], #4           @ publish NavState word i
    adds  r1, #1
    subs  r2, #1
    bne   1b
    ldr   r0, =0x20400040        @ READY flag, written LAST
    movs  r1, #1
    str   r1, [r0]
2:  b     2b
