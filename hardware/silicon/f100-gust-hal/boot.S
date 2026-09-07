    .syntax unified
    .cpu cortex-m3
    .thumb
@ Boot shim for the gust:hal on-target rung (STM32F100, 8 KB SRAM @ 0x20000000).
@
@   0x20000000..0x20000400  stack (SP = 0x20000400)
@   0x20000480  CLOCK_EN   <- written by the HOST before resume; the ONE variable
@   0x20000484  read_idcode() result
@   0x20000488  gpio_probe(CLOCK_EN) result
@   0x2000048C  completion marker (0xC0FFEE00)
@   0x20000500  globals table (R9)
@   0x20000600  linear memory (R11), 0x1000 B
    .equ SP_TOP,    0x20000400
    .equ CLOCK_EN,  0x20000480
    .equ RES_ID,    0x20000484
    .equ RES_ODR,   0x20000488
    .equ DONE,      0x2000048C
    .equ GLOBALS,   0x20000500
    .equ LINMEM,    0x20000600
    .equ LINMEM_SZ, 0x1000

    .section .vectors, "a"
    .word SP_TOP
    .word reset + 1

    .text
    .global reset
    .thumb_func
reset:
    ldr  sp, =SP_TOP
@ Poison the result words so "the program never wrote them" cannot be misread as a
@ legitimate zero — the distinction the AFD-107 rung turned on. CLOCK_EN is NOT
@ poisoned: the host wrote it before resume.
    ldr  r1, =0xDEADBEEF
    ldr  r0, =RES_ID
    str  r1, [r0]
    ldr  r0, =RES_ODR
    str  r1, [r0]
    ldr  r0, =DONE
    str  r1, [r0]

@ Establish the embedder ABI. gust_hal.c is compiled -ffixed-r9/-r10/-r11 so it
@ cannot disturb these between lowered calls; verify-embedder proves that on the
@ emitted code rather than on the flags.
    ldr  r9,  =GLOBALS
    ldr  r10, =LINMEM_SZ
    ldr  r11, =LINMEM

    bl   read_idcode
    ldr  r1, =RES_ID
    str  r0, [r1]

    ldr  r0, =CLOCK_EN
    ldr  r0, [r0]
    bl   gpio_probe
    ldr  r1, =RES_ODR
    str  r0, [r1]

    ldr  r0, =0xC0FFEE00
    ldr  r1, =DONE
    str  r0, [r1]
1:  b    1b
