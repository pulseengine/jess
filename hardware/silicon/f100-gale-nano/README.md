# gale-nano 0.7.0 on real STM32F100 silicon — H3's second half, ADVANCED not COMPLETE

## What executed

gale-nano 0.7.0 (digest-pinned, `546531952a5c…`) lowered for `cortex-m3` and linked against
jess's embedder — the real `gust:hal` MMIO from AFD-109, the generic embedder-init apply loop
from AFD-107, and a boot shim — then flashed to an STM32VLDISCOVERY and run over SWD.

```
LEG (only the ADMIT word differs)   poll-task#  handle    state     completion
  task admitted (baseline)          00000000    00000000  00000001  c0ffee00
  no admit (negative control)       00000000    deadbeef  deadbeef  c0ffee00
```

**gale-nano's code runs on the part.** `exec_admit` works and gale's *own* view agrees with
the wasmtime reference: `exec_state(handle) == 1`, which is exactly what TEST-PIX-035 asserts
("admitted task starts in state 1"). `handle == 0` is correct, not a failure — jess already
recorded that gale-nano hands out handle 0.

**`exec_poll_round` does not dispatch.** `poll-task` is reached **0** times. The wasmtime
reference, re-run green the same day against the same pinned artifact, reaches it **once**:

```
with-admit()          1   a round after admit polls the task ONCE
without-admit()       0   CONTROL: same round, no admit -> poll-task NOT reached
state-before-round()  1   admitted task starts in state 1
```

Both sides use the same constants (`PRIO=1`, `DEADLINE_LO=1000`, `NOW_LO=2000`) — taken from
`app/dispatch-driver`, not invented here.

## The likely cause, and why it is not yet proven

gale-nano's **component manifest** declares:

```
import gust:os/taskdisp@0.1.0;
import gust:hal/mmio@0.1.0;
export gust:os/time@0.1.0;  export gust:os/log@0.1.0;  export gust:os/spawn@0.1.0;
export gust:os/exec@0.1.0;  export gust:os/timer@0.1.0;
```

So the embedder owes exactly **two** things — `poll-task` and `read32`/`write32` — which is
what gale#223 says in words.

But `synth --relocatable --all-exports` emits **six** undefined symbols:

```
deadline  poll-task  read32  set-deadline  slept-status  state
```

and the emitted export set does not match the declared one: it emits
`gust:sched/tasks@0.1.0#*` (an interface the component does **not** export) and emits
**nothing** for `gust:os/time@0.1.0` (which it **does**).

Nothing in the object distinguishes the two real obligations from the four that are the
component's own internals. Satisfying them the obvious way is measurably wrong:

- **Stubbing** `set-deadline`/`slept-status`/`state` inert replaced gale's task-state store.
  Aliasing them onto gale's own exports with `objcopy --redefine-sym` is correct and is what
  `build.sh` does. (`@` begins an ARM comment, so an `.S` label cannot name these; this is the
  same technique `cascade-invoke` already uses.)
- `deadline` has **nothing to alias to**, because the `gust:os/time` export was not lowered.
  Returning `0` was measured to break dispatch; a `now + ticks` guess did not fix it either.
  jess is not going to keep guessing at a gale semantic — that is gale's lane.

**Not claimed:** that this is a gale defect. gale-nano's component is self-consistent and the
wasmtime path works. The asymmetry is in the lowering, and the remaining gap is unproven.

## Why the control is not vacuous

- Both legs run the **byte-identical flashed image**; one host-written word at `0x20000480`
  differs. Exactly one variable.
- `poll-task` **counts** its invocations. A stub that returns a value and records nothing makes
  "poll-round drained the task" and "poll-round did nothing" identical readings — the vacuity
  `tools/dispatch/run.sh` was written to avoid, in its own words.
- `POLL_COUNT` is a counter, so it cannot be poisoned; the **completion marker** is therefore
  load-bearing, and it is present in **both** legs. "0 invocations" is distinguished from "the
  CPU never ran".
- `exec_state` is read back so the result rests on **gale's own view**, not only jess's counter.
  That is what proves admit succeeded and localises the failure to `poll-round`.

## Scope

- **Executed on silicon:** gale-nano's lowered code, `exec_admit`, `exec_state`,
  `exec_poll_round`, and jess's `read32` linked in.
- **Not achieved:** dispatch. H3's second half is **not** complete.
- Nothing on the RT1176; the debug adapter is in transit.

`build.sh` verifies the pinned digest before lowering, asserts the seam is exactly the three
symbols jess supplies, checks the 11 data segments fit the 4 KB window on the real 8 KB part,
and gates on `verify-embedder` plus its refusal control.
