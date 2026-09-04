@ Minimal MPU feasibility probe: program ONE region, write inside it, write outside it.
@ If Renode models the Cortex-M MPU, the outside write raises MemManage and CFSR shows
@ DACCVIOL. If it does not model it, BOTH writes land and the markers are identical —
@ which is the vacuous case this probe exists to distinguish.
    .syntax unified
    .cpu cortex-m7
    .fpu fpv5-d16
    .thumb
    .equ MPU_TYPE, 0xE000ED90
    .equ MPU_CTRL, 0xE000ED94
    .equ MPU_RNR,  0xE000ED98
    .equ MPU_RBAR, 0xE000ED9C
    .equ MPU_RASR, 0xE000EDA0
    .equ SHCSR,    0xE000ED24
    .equ CFSR,     0xE000ED28
    .equ MARK,     0x20030000

    .section .vectors, "a"
    .word _stack_top
    .word _reset + 1
    .word _fault + 1          @ NMI
    .word _fault + 1          @ HardFault
    .word _memmanage + 1      @ MemManage

    .text
    .global _reset
    .thumb_func
_reset:
    ldr   sp, =_stack_top
    ldr   r10, =MARK
    movs  r0, #0
    str   r0, [r10, #0]       @ [MARK+0]  = MPU_TYPE DREGION (0 if no MPU modelled)
    str   r0, [r10, #4]       @ [MARK+4]  = inside-write readback
    str   r0, [r10, #8]       @ [MARK+8]  = outside-write readback
    str   r0, [r10, #12]      @ [MARK+12] = CFSR after
    str   r0, [r10, #16]      @ [MARK+16] = fault taken marker

    @ Does this CPU even report MPU regions?
    ldr   r0, =MPU_TYPE
    ldr   r1, [r0]
    str   r1, [r10, #0]

    @ enable MemManage fault
    ldr   r0, =SHCSR
    ldr   r1, [r0]
    orr   r1, r1, #(1 << 16)
    str   r1, [r0]

    @ region 0: base 0x20000000, size 32KB (RASR SIZE=14 -> 2^15), AP=011 full access, ENABLE
    ldr   r0, =MPU_RNR
    movs  r1, #0
    str   r1, [r0]
    ldr   r0, =MPU_RBAR
    ldr   r1, =0x20000000
    str   r1, [r0]
    ldr   r0, =MPU_RASR
    ldr   r1, =((3 << 24) | (14 << 1) | 1)
    str   r1, [r0]
    @ enable MPU, background region DISABLED so anything outside region 0 faults
    ldr   r0, =MPU_CTRL
    movs  r1, #1
    str   r1, [r0]
    dsb
    isb

    @ INSIDE the region — must succeed
    ldr   r0, =0x20001000
    ldr   r1, =0x1111AAAA
    str   r1, [r0]
    ldr   r2, [r0]
    str   r2, [r10, #4]

    @ OUTSIDE the region (0x20008000 is past 32KB) — must fault if the MPU is modelled
    ldr   r0, =0x20008000
    ldr   r1, =0x2222BBBB
    str   r1, [r0]
    ldr   r2, [r0]
    str   r2, [r10, #8]
1:  b     1b

    .thumb_func
_memmanage:
    ldr   r10, =MARK
    ldr   r0, =CFSR
    ldr   r1, [r0]
    str   r1, [r10, #12]
    ldr   r1, =0x1E55FA17
    str   r1, [r10, #16]
2:  b     2b
    .thumb_func
_fault:
    ldr   r10, =MARK
    ldr   r1, =0x1E55DEAD
    str   r1, [r10, #16]
3:  b     3b
