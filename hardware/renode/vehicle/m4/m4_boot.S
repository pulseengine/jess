@ Minimal i.MX RT1176 Cortex-M4 (FPv4-SP) bring-up for the jess 3-core vehicle sim.
@ The M4 is the on-die sensor-offload core (DD-018 T2). This stub writes an
@ incrementing heartbeat to the M7<->M4 shared-memory ring (SHMEM @ 0x20400000,
@ the relay-bus carrier region, DD-009) so the multi-core model demonstrates the
@ M4 executing + the shared-mem link live. Vectors/text/stack in OCRAM (shared by
@ both cores on the RT1176 sysbus). (TEST-PIX-019, Stage 4 multi-core.)
    .syntax unified
    .cpu cortex-m4
    .thumb

    .section .vectors, "a"
    .word _m4_stack_top         @ initial SP
    .word reset + 1             @ reset vector (thumb bit)

    .text
    .thumb_func
    .global reset
reset:
    ldr   r0, =_m4_stack_top
    mov   sp, r0
    ldr   r0, =0x20400000       @ SHMEM heartbeat word (M7<->M4 ring)
    movs  r1, #0
1:  adds  r1, #1
    str   r1, [r0]             @ publish heartbeat -> shared memory
    b     1b
