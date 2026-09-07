    .syntax unified
    .cpu cortex-m3
    .thumb
@ Run gale-nano 0.7.0's dispatch loop on real STM32F100 silicon (H3, second half).
@
@ SRAM map (the REAL part: 8 KB at 0x20000000):
@   0x20000000..0x20000400  stack (SP = 0x20000400)
@   0x20000480  ADMIT      <- written by the HOST before resume; the ONE variable
@   0x20000484  POLL_COUNT    incremented by the `poll-task` embedder stub
@   0x20000488  admit handle returned by exec_admit
@   0x2000048C  completion marker (0xC0FFEE00)
@   0x20000500  globals table (R9), 10 globals
@   0x20000600  linear memory (R11), 0x1000 B  (gale-nano's highest data addr is 0xC11)
    .equ SP_TOP,    0x20000400
    .equ ADMIT,     0x20000480
    .equ POLL_COUNT,0x20000484
    .equ RES_H,     0x20000488
    .equ RES_ST,    0x20000490      @ exec_state(handle) — gale's OWN view
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
@ POLL_COUNT must start at 0 — it is a counter, not a sentinel, so it cannot be
@ poisoned. That makes "0 invocations" and "the program never ran" the same reading,
@ which is why the completion marker below is load-bearing rather than decorative:
@ it is the only thing that separates them.
    movs r0, #0
    ldr  r1, =POLL_COUNT
    str  r0, [r1]
    ldr  r1, =0xDEADBEEF
    ldr  r0, =RES_H
    str  r1, [r0]
    ldr  r0, =RES_ST
    str  r1, [r0]
    ldr  r0, =DONE
    str  r1, [r0]

@ Apply the 11 active data segments and seed the 10 R9 globals BEFORE any export runs
@ (AFD-107). Called first because the C helper is free to clobber r9/r10/r11.
    ldr  r0, =LINMEM
    ldr  r1, =GLOBALS
    bl   jess_wasm_apply_init

    ldr  r9,  =GLOBALS
    ldr  r10, =LINMEM_SZ
    ldr  r11, =LINMEM

@ exec_admit(prio, deadline_lo, deadline_hi) -> handle
    ldr  r0, =ADMIT
    ldr  r0, [r0]
    cmp  r0, #0
    beq  1f
@ THE SAME CONSTANTS AS THE WASMTIME REFERENCE (app/dispatch-driver), not invented here.
@ A first run used deadline=(0,0) and now=(0,0); admit returned handle 0 and poll-round
@ never reached poll-task. That is not a lowering defect and not a gale defect — the
@ reference's own comment says why: NOW must be PAST the deadline for an admitted task to
@ be READY. Reporting that first result as "gale-nano does not dispatch on silicon" would
@ have been a false report against a supplier (the meld#390 shape). The differential is
@ only a differential if both sides are driven identically.
    movs r0, #1                 @ prio           = PRIO
    movw r1, #1000              @ deadline_lo    = DEADLINE_LO
    movs r2, #0                 @ deadline_hi    = DEADLINE_HI
    bl   exec_admit
    ldr  r1, =RES_H
    str  r0, [r1]
@ Ask gale for ITS view of the task, independent of jess's counter. The wasmtime oracle
@ asserts "admitted task starts in state 1"; if silicon reports something else, admit did
@ not take, and the poll-count is a downstream symptom rather than the finding.
    bl   exec_state
    ldr  r1, =RES_ST
    str  r0, [r1]
1:
@ exec_poll_round(now_lo, now_hi) — drives one round. With a task admitted this must
@ reach `poll-task`; without one it must not. That is the whole differential.
    movw r0, #2000              @ now_lo = NOW_LO (past the deadline -> task is READY)
    movs r1, #0                 @ now_hi = NOW_HI
    bl   exec_poll_round

    ldr  r0, =0xC0FFEE00
    ldr  r1, =DONE
    str  r0, [r1]
2:  b    2b
