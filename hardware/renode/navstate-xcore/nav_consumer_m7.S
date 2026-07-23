@ NavState consumer (M7 flight core) for the inter-core crossing oracle (REQ-PIX-007,
@ TEST-PIX-030). Polls the READY flag @0x20400040 (acquire), then copies the 16-word
@ NavState message from the SHMEM ring @0x20400000 to its own DTCM output @0x20010000,
@ byte-exact. Vectors/text in ITCM @0x0 (M7 boots here). The robot asserts the DTCM
@ output equals the producer's pattern word[i]=0x4E560000+i — proving the NavState
@ crossed M4->SHMEM->M7 byte-exact over shared SRAM.
    .syntax unified
    .cpu cortex-m7
    .thumb
    .section .vectors, "a"
    .word _m7_stack_top
    .word reset + 1
    .text
    .thumb_func
    .global reset
reset:
    ldr   sp, =_m7_stack_top
    ldr   r3, =0x20400040        @ READY flag
1:  ldr   r1, [r3]               @ spin until producer publishes (acquire)
    cmp   r1, #0
    beq   1b
    ldr   r0, =0x20400000        @ SHMEM NavState src
    ldr   r4, =0x20010000        @ M7 DTCM output dst
    movs  r2, #16
2:  ldr   r1, [r0], #4
    str   r1, [r4], #4
    subs  r2, #1
    bne   2b
3:  b     3b
