    .syntax unified
    .cpu cortex-m3
    .thumb
@ jess's EMBEDDER HARNESS for the gust:os seam — NOT an implementation of gust:os.
@
@ gale owns gust:os semantics (DD-025, gale#223/#224 are still open on the timer).
@ These exist so gale-nano's lowered code can be EXECUTED on real silicon and the
@ dispatch seam observed. They are the on-target counterpart of app/gust-dispatch-probe,
@ which plays the same role for the wasmtime oracle (TEST-PIX-035).
@
@ WRITTEN IN ASSEMBLY ON PURPOSE, for two reasons:
@   1. The import names are WIT kebab-case (`poll-task`, `set-deadline`, ...). GCC cannot
@      declare them: `__asm__("poll-task")` emits an unquoted `.type poll-task, %function`
@      and the assembler rejects it. A quoted label in .S does work.
@   2. It makes the calling convention unfalsifiable. `deadline` is `func(u64, u64) -> u64`
@      and the core flattening of u64 is not something to guess: a wrong C prototype
@      silently corrupts registers. A leaf that sets its return registers and returns is
@      correct for ANY argument shape, because under AAPCS the CALLER cleans the stack.
@ They also must not touch r9/r10/r11 — synth's embedder contract — which is trivially
@ true here and is checked by verify-embedder over the linked image.

    .equ POLL_COUNT, 0x20000484      @ must match boot.S

    .text

@ poll-task(id: u32) -> u32
@ COUNTS its invocations. A stub that returns a value and records nothing makes
@ "poll-round drained the task" and "poll-round did nothing" observationally
@ IDENTICAL — the exact vacuity tools/dispatch/run.sh was written to avoid, in its
@ own words: "jess's existing taskdisp implementations returned 0 and recorded
@ NOTHING". The counter is what makes the control pair mean anything.
    .global "poll-task"
    .thumb_func
"poll-task":
    ldr  r1, =POLL_COUNT
    ldr  r2, [r1]
    adds r2, r2, #1
    str  r2, [r1]
    movs r0, #1              @ 1 = complete. Polarity MEASURED in AFD-067: returning 0
    bx   lr                  @ leaves the task ready and it is re-polled every round.

@ time.deadline(now: u64, ticks: u64) -> u64  =  now + ticks
@
@ NOTE THIS IS A JESS GUESS AT A GALE SEMANTIC, and it is here only to isolate one
@ variable. gale-nano's component manifest EXPORTS gust:os/time@0.1.0 — this is NOT an
@ embedder import (its only two are taskdisp and mmio) — but synth's --relocatable
@ lowering emits no symbol for that export and leaves `deadline` dangling, so there is
@ nothing to alias to. Returning 0 was MEASURED to break dispatch on silicon: admit
@ succeeded (exec_state == 1) and poll-round never reached poll-task.
@ u64 args flatten to (lo,hi) pairs in r0..r3; a u64 result returns in r0:r1.
    .global "deadline"
    .thumb_func
"deadline":
    adds r0, r0, r2
    adcs r1, r1, r3
    bx   lr

@ gust:sched/tasks {set-deadline, slept-status, state} are NOT stubbed here.
@
@ gale-nano DEFINES them (as `gust:sched/tasks@0.1.0#...`) and ALSO imports them by bare
@ name: synth's --relocatable lowering does not wire a component's intra-component imports
@ to its own exports, so they arrive as undefined symbols and look like an embedder
@ obligation. They are not. In the wasmtime graph wac infers exactly this wiring (see
@ tools/dispatch/compose.wac, which names only taskdisp and mmio and leaves `...` to
@ inference).
@
@ Stubbing them was measured to be WRONG, not merely redundant: with inert stubs returning
@ 0, exec_admit returned handle 0 and poll-round never reached poll-task on silicon —
@ jess had replaced gale's task-state store with a no-op. build.sh now aliases gale's own
@ exports onto the imported names with objcopy --redefine-sym (the same technique
@ cascade-invoke already uses, because `@` begins an ARM comment and an asm label
@ truncates there).
