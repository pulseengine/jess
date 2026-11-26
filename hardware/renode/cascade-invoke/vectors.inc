@ The vector table shared by every cascade-invoke image (boot.S, boot-soak.S, boot-ekf.S),
@ pulled in with #include so each image and each negative control linked from those objects
@ carries the same table.
@
@ WHY A FULL TABLE. Until this file every image had a 2-word table (SP, reset), so .text began
@ at 0x8 and the third word onward was code. On silicon the loader halts PX4, not resets it, so
@ an interrupt PX4 enabled can be pending at resume. B2 (2026-11-22) measured 58 of 60 runs dying,
@ and SRC_SRSR read 0x10000004, an M7 LOCKUP (hardware/silicon/evidence/lockup-rt1176-2026-11-24/).
@ PRIMASK=1 before resume gave 10 of 10; the loader does that. This table is the image side:
@ every exception now lands in a handler that exists, records what fired, and either returns
@ (an interrupt) or parks (a fault) instead of fetching code bytes as a handler address.
@
@ SIZE: 16 system entries + 240 external, the Cortex-M7 architectural maximum, so the table is
@ complete whatever the RT1176 implements. 256 words = 1024 B; VTOR needs 1024-B alignment for
@ that and the table sits at 0x00000000. build.sh asserts all 256 entries in every linked image.
@
@ THE LOG, 6 words at jess_exc_log (0x20011F00, link.ld). It is initialised by the ELF LOAD, not
@ by code, so an interrupt taken on the very first instruction after resume is still recorded:
@   +0  magic 0x1E55E7C0   absent = the log was not loaded with this image, read nothing into it
@   +4  exceptions taken
@   +8  first exception number (IPSR; 16+n is IRQ n)
@   +12 last exception number
@   +16 0xDEADFA17 when a fault parked the core, else 0
@   +20 the faulting PC from the stacked frame, else 0
@ Renode takes no exceptions in these images, so the oracles assert +4 == 0 there.

    .section .vectors, "a"
    .global jess_vectors
jess_vectors:
    .word _stack_top
    .word _reset + 1
    .rept 254
    .word jess_default_handler + 1
    .endr

    .section .exclog, "aw"
    .balign 4
    .global jess_exc_log
jess_exc_log:
    .word 0x1E55E7C0, 0, 0, 0, 0, 0

    .text
    .global jess_default_handler
    .thumb_func
jess_default_handler:
    mrs   r0, ipsr
    ldr   r1, =jess_exc_log
    ldr   r2, [r1, #4]
    adds  r2, r2, #1
    str   r2, [r1, #4]
    cmp   r2, #1
    bne   1f
    str   r0, [r1, #8]
1:  str   r0, [r1, #12]
    cmp   r0, #16
    blo   2f
    @ IRQ n = IPSR - 16. Disable it in the NVIC (ICER[n/32] bit n%32) so a level-triggered
    @ source left asserted by PX4 cannot re-enter forever, then return to the image.
    subs  r0, r0, #16
    and   r2, r0, #31
    movs  r3, #1
    lsls  r3, r3, r2
    lsrs  r0, r0, #5
    ldr   r2, =0xE000E180
    str   r3, [r2, r0, lsl #2]
    dsb
    isb
    bx    lr
2:  cmp   r0, #15
    bne   3f
    @ SysTick left running by PX4: stop it and return.
    ldr   r2, =0xE000E010
    movs  r3, #0
    str   r3, [r2]
    dsb
    bx    lr
3:  cmp   r0, #14
    bne   4f
    @ PendSV left pending by PX4: clear it (ICSR.PENDSVCLR) and return.
    ldr   r2, =0xE000ED04
    mov   r3, #0x08000000
    str   r3, [r2]
    dsb
    bx    lr
4:  @ NMI, HardFault, MemManage, BusFault, UsageFault, SVCall, DebugMon or reserved: a fault in
    @ the image or the part. Record the stacked PC and park, so the core halts here instead of
    @ locking up and resetting the board.
    tst   lr, #4
    ite   eq
    mrseq r2, msp
    mrsne r2, psp
    ldr   r2, [r2, #24]
    str   r2, [r1, #20]
    ldr   r2, =0xDEADFA17
    str   r2, [r1, #16]
5:  b     5b
    .ltorg
