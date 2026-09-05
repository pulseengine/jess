@ MPU ENFORCEMENT PROBE — does this CPU model actually deny an out-of-grant access?
@
@ DESIGN (the first version of this was wrong and would have mis-measured any platform
@ that DOES enforce): with PRIVDEFENA=0 a single data region is not enough. Instruction
@ fetch, the stack, and the result markers must ALL sit inside a granted region, or the
@ probe faults on exception entry or on its own bookkeeping rather than on the access
@ under test. So: grant CODE and DATA, leave a HOLE granted to nobody, and write into
@ the hole. Same shape as gale's mpu_spike (gale#348).
@
@ Parameterised so one source measures several platforms:
@   CODE_BASE/CODE_SZ  region 0 — where .text lives (SZ is the RASR SIZE field)
@   DATA_BASE/DATA_SZ  region 1 — stack + markers
@   HOLE_ADDR          an address inside NO region; the access under test
@   MARK               marker block, must be inside the DATA region
    .syntax unified
    .thumb
    .equ MPU_CTRL, 0xE000ED94
    .equ MPU_RNR,  0xE000ED98
    .equ MPU_RBAR, 0xE000ED9C
    .equ MPU_RASR, 0xE000EDA0
    .equ MPU_TYPE, 0xE000ED90
    .equ SHCSR,    0xE000ED24
    .equ CFSR,     0xE000ED28

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
    str   r0, [r10, #0]
    str   r0, [r10, #4]
    str   r0, [r10, #8]
    str   r0, [r10, #12]
    str   r0, [r10, #16]

    ldr   r0, =MPU_TYPE       @ [MARK+0] = advertised region count
    ldr   r1, [r0]
    str   r1, [r10, #0]

    ldr   r0, =SHCSR          @ enable MemManage
    ldr   r1, [r0]
    orr   r1, r1, #(1 << 16)
    str   r1, [r0]

    ldr   r0, =MPU_RNR        @ region 0 = CODE
    movs  r1, #0
    str   r1, [r0]
    ldr   r0, =MPU_RBAR
    ldr   r1, =CODE_BASE
    str   r1, [r0]
    ldr   r0, =MPU_RASR
    ldr   r1, =((3 << 24) | (CODE_SZ << 1) | 1)
    str   r1, [r0]

    ldr   r0, =MPU_RNR        @ region 1 = DATA (stack + markers)
    movs  r1, #1
    str   r1, [r0]
    ldr   r0, =MPU_RBAR
    ldr   r1, =DATA_BASE
    str   r1, [r0]
    ldr   r0, =MPU_RASR
    ldr   r1, =((3 << 24) | (DATA_SZ << 1) | 1)
    str   r1, [r0]

    ldr   r0, =MPU_CTRL       @ MPU on, background region DISABLED
    movs  r1, #1
    str   r1, [r0]
    dsb
    isb

    movs  r0, #1              @ [MARK+16] = reached the granted store
    ldr   r1, =0x51AE0001
    str   r1, [r10, #16]

    ldr   r0, =DATA_BASE      @ GRANTED store, inside region 1
    ldr   r1, =0x1111AAAA
    str   r1, [r0, #0x40]
    ldr   r2, [r0, #0x40]
    str   r2, [r10, #4]

    ldr   r1, =0x51AE0003     @ [MARK+16] = about to touch the hole
    str   r1, [r10, #16]

#ifdef UNPRIV
    @ Drop to UNPRIVILEGED (CONTROL.nPRIV=1) immediately before the access under test.
    @ gale#348: Renode ignores PRIVDEFENA and treats a PRIVILEGED background access as
    @ granted, so a privileged probe measures that one gap rather than "the MPU". The
    @ granted regions are AP=0b011 (full access, priv+unpriv), so this store still works.
    mrs   r0, CONTROL
    orr   r0, r0, #1
    msr   CONTROL, r0
    isb
#endif

    ldr   r0, =HOLE_ADDR      @ THE ACCESS UNDER TEST — granted to nobody
    ldr   r1, =0x2222BBBB
    str   r1, [r0]
    ldr   r2, [r0]
    str   r2, [r10, #8]       @ if this lands, the MPU did NOT enforce
    ldr   r1, =0xBADF0011
    str   r1, [r10, #16]      @ FELL-THROUGH
1:  b     1b

    .thumb_func
_memmanage:
    ldr   r10, =MARK
    ldr   r0, =CFSR
    ldr   r1, [r0]
    str   r1, [r10, #12]
    ldr   r1, =0x1E55FA17     @ DENIED — the MPU enforced
    str   r1, [r10, #16]
2:  b     2b
    .thumb_func
_fault:
    ldr   r10, =MARK
    ldr   r1, =0x1E55DEAD     @ escalated (usually: stack or fetch outside a grant)
    str   r1, [r10, #16]
3:  b     3b
