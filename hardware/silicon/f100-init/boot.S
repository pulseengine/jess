    .syntax unified
    .cpu cortex-m3
    .thumb
@ Boot shim for the embedder-init on-target proof (STM32F100, 8 KB SRAM @ 0x20000000).
@
@ SRAM map (everything below 0x20002000 — the REAL part, not an assumed 128 KB):
@   0x20000000..0x20000400   stack (grows down to SP = 0x20000400)
@   0x20000480   APPLY flag   <- written by the HOST before resume; the ONE variable
@   0x20000484   read_data result
@   0x20000488   read_global result
@   0x2000048C   completion marker (0xC0FFEE00)
@   0x20000500   globals table (R9), 64 B
@   0x20000600   linear memory (R11), 0x1000 B
@
@ The apply decision is a RUNTIME input, not a build flag, so the negative control
@ runs the BYTE-IDENTICAL flashed image and differs in exactly one word (AFD-048).
    .equ SP_TOP,    0x20000400
    .equ APPLY,     0x20000480
    .equ RES_DATA,  0x20000484
    .equ RES_GLOB,  0x20000488
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
    ldr  r1, =0xDEADBEEF
@ Poison BOTH regions first. Without this, "init not applied" could read as an
@ accidental zero and be indistinguishable from a legitimately-zero value; the
@ poison makes the FAILING case observable, which is what makes the pass mean
@ something. The result/flag block (0x20000480..0x2000048F) is deliberately NOT
@ poisoned — the host wrote the flag there before resume.
    ldr  r0, =GLOBALS
    movs r2, #16
1:  str  r1, [r0], #4
    subs r2, r2, #1
    bne  1b
    ldr  r0, =LINMEM
    ldr  r2, =(LINMEM_SZ / 4)
2:  str  r1, [r0], #4
    subs r2, r2, #1
    bne  2b

    ldr  r0, =APPLY
    ldr  r0, [r0]
    cmp  r0, #0
    beq  4f
    ldr  r0, =LINMEM
    ldr  r1, =GLOBALS
    bl   jess_wasm_apply_init      @ C: free to clobber r9/r10/r11, so call it FIRST
4:
@ NOTE: this branch target is a NUMERIC local label on purpose. As a named label
@ (`skip_apply:`) it entered the symbol table, and synth's verify-embedder then
@ attributed the three ABI-establishing writes below to <skip_apply> rather than
@ to <reset> — so `--allow-writer reset` did not match and the check refused a
@ conforming image. The acknowledged establishment site must be the symbol the
@ writes are actually attributed to, or the acknowledgement names the wrong thing.

@ Install the embedder ABI only AFTER the C helper has returned.
    ldr  r9,  =GLOBALS
    ldr  r10, =LINMEM_SZ
    ldr  r11, =LINMEM

    bl   read_data
    ldr  r1, =RES_DATA
    str  r0, [r1]
    bl   read_global
    ldr  r1, =RES_GLOB
    str  r0, [r1]

    ldr  r0, =0xC0FFEE00
    ldr  r1, =DONE
    str  r0, [r1]
3:  b    3b
