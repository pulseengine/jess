@ TEST-PIX-036 — the falcon ESTIMATOR (ekf#estimate) on emulated RT1176 Cortex-M7, N ticks.
@
@ WHY A SEPARATE IMAGE, and this one matters more than the soak's reason. TEST-PIX-032 carries
@ the ONLY FROZEN baseline in this suite: EXP/EXPP in run-oracle.sh came from relay's SIL
@ reference under falcon v1.134.1 and are hardcoded, so unlike every other number here they are
@ not recomputed from the module under test. AFD-122 measured that they still hold bit-exact on
@ v1.139. Calling another stage inside that image would advance shared instance state and move
@ the one number in this repo that cannot go self-consistently green. So this rung gets its own
@ image and its own parking area, and touches neither.
@
@ WHY THE ESTIMATOR: jess's on-target differential has only ever invoked rate and mixer. ekf,
@ attitude and position are in the fused image and are NEVER CALLED — and relay's estimator fix,
@ the change behind the v1.134 -> v1.139 move that invalidated 18 of their closed-loop tests,
@ lives in exactly that blind spot (AFD-122). This is the estimator half of it.
@
@ Everything up to the call is byte-for-byte the boot.S prologue: FPU on, jess_init applies the
@ data segments and globals, then the embedder registers are established AFTER init and BEFORE
@ any export runs (synth#1131, docs/embedder-abi-relocatable-arm.md).
    .syntax unified
    .cpu cortex-m7
    .fpu fpv5-d16
    .thumb

    .equ LINMEM,  0x20000000        @ fp  (r11) — linear memory base
    .equ LINSIZE, 0x00010000        @ sl  (r10) — linear memory size
    .equ GLOBALS, 0x20010100        @ r9        — globals table base
    @ Tick count. The oracle passes the SAME N to the reference, and build.sh records the
    @ EFFECTIVE value to $OUT/ekf.n so a consumer reads what was BUILT rather than re-deriving
    @ it from this line — the `iface.ver` pattern, adopted here for the same reason: a value
    @ grepped out of a source file is a value that goes stale the moment anything overrides it.
    @ Overridable so a longer run needs no source edit: EKF_N=1024 build.sh. Measuring the
    @ estimator's divergence over 1024 ticks (AFD-134) required hand-editing this constant,
    @ which meant the measurement could not be reproduced from the repo as it stood.
    .ifndef EKF_N
    .equ EKF_N,   16
    .endif

    .section .vectors, "a"
    .word _stack_top
    .word _reset + 1

    .text
    .global _reset
    .thumb_func
_reset:
    ldr   sp, =_stack_top

    @ FPU on — a cortex-m7dp hard-float image faults on the first VFP op without this. This
    @ rung needs it for a second reason: ekf#estimate takes its six f32 arguments FLATTENED,
    @ so they are passed in VFP registers rather than through memory like rate#tick's pointer.
    ldr   r0, =0xE000ED88
    ldr   r1, [r0]
    orr   r1, r1, #0x00F00000
    str   r1, [r0]
    dsb
    isb

    @ The two instantiation promises (AFD-051), applied from tables extracted from THIS module.
    bl    jess_init

    @ Establish the embedder registers AFTER init, before any export runs.
    ldr   r9,  =GLOBALS
    ldr   r10, =LINSIZE
    ldr   r11, =LINMEM

    @ jess_call_ekf(EKF_N). NO argument pointer: ekf#estimate's six flattened f32 come from
    @ IMU_WORDS inside the harness, not from a linear-memory vector — 6 flat params is under
    @ the Canonical ABI flattening limit of 16, so there is no argument record to place.
    @ That is the whole ABI contrast this rung adds; rate#tick needed ARGOFF because 18 > 16.
    @ Parks the trip count, tick-1 state, tick-N state, the FNV-1a fold over every tick's
    @ fourteen words, and its own sentinel, at EKF_BASE (0x20011400) — below .bss at 0x20012000.
    mov   r0, #EKF_N
    bl    jess_call_ekf

1:  b     1b
