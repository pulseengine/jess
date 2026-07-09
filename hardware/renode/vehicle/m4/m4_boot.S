@ Minimal i.MX RT1176 Cortex-M4 (FPv4-SP) bring-up for the jess 3-core vehicle sim.
@ The M4 is the on-die sensor-offload core (DD-018 T2). It (1) RINGS THE NXP MU
@ DOORBELL — writes a sentinel to bInstance TR0, which the IMXRT700 MU model
@ delivers to the M7-side aInstance RR0 (0x40C4C280) and raises AInstanceIRQ: the
@ real NXP IPCF/RPMsg doorbell datapath, no longer just wired but DRIVEN — then
@ (2) writes an incrementing heartbeat to the M7<->M4 shared-memory ring
@ (SHMEM @ 0x20400000, the relay-bus / RPMsg-vring carrier, DD-009). Vectors/text/
@ stack in OCRAM (shared by both cores on the RT1176 sysbus). (TEST-PIX-019.)
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

    @ (1) Ring the MU doorbell: sentinel -> bInstance TR0 (0x40C4D000 + 0x200).
    @ The MU model delivers it to aInstance RR0 (M7 side, 0x40C4C280) and asserts
    @ AInstanceIRQ. The interrupt-capable NXP MU/RPMsg doorbell datapath, DRIVEN by
    @ firmware — distinct from the polled SHMEM ring below.
    ldr   r0, =0x40C4D200       @ MU bInstance TR0 (M4 transmit)
    ldr   r1, =0x0000BEEF       @ doorbell payload sentinel
    str   r1, [r0]

    @ (2) Heartbeat loop -> the SHMEM ring (the vring payload carrier).
    ldr   r0, =0x20400000       @ SHMEM heartbeat word (M7<->M4 ring)
    movs  r1, #0
1:  adds  r1, #1
    str   r1, [r0]             @ publish heartbeat -> shared memory
    b     1b
