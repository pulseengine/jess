@ Minimal i.MX RT1176 (Cortex-M7) bring-up smoke for the jess Renode platform.
@ Vector table at ITCM 0x0; reset sets SP, enables LPUART1 TX (CTRL.TE), writes a
@ banner to LPUART1 (0x4007C000: CTRL @ +0x18, DATA @ +0x1C), then spins.
@ Validates CPU + ITCM/DTCM + LPUART + the vector-table reset path. (REQ-PIX-005)
    .syntax unified
    .cpu cortex-m7
    .thumb

    .section .vectors, "a"
    .word _stack_top            @ initial SP (read from 0x0 on reset)
    .word reset + 1             @ reset vector (thumb bit)

    .text
    .thumb_func
    .global reset
reset:
    ldr   r0, =_stack_top
    mov   sp, r0
    ldr   r0, =0x4007C000       @ LPUART1 base (RT1176)
    movw  r3, #0x0000           @ CTRL.TE (bit 19) = 0x00080000 — enable transmitter
    movt  r3, #0x0008
    str   r3, [r0, #0x18]       @ CTRL
    ldr   r1, =msg
1:  ldrb  r2, [r1], #1
    cbz   r2, 2f
    str   r2, [r0, #0x1C]       @ DATA — transmit byte
    b     1b
2:  b     2b                    @ spin forever

    .align 2
msg:
    .asciz "JESS-RT1176 boot OK\n"
