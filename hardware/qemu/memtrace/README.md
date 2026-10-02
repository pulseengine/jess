# memtrace — what the lowered falcon cascade actually touches in linear memory

A QEMU TCG plugin plus an analyser, built for **synth#1436**: the synth-lowered
`ekf#estimate` disagrees with wasmtime on part of the returned state, bit-identically on Renode,
QEMU and the real i.MX RT1176 (AFD-125, AFD-132). Every external variable had already been
eliminated — loom, the emulator, the compiler version, the argument marshalling, the return ABI.
synth's first disassembly pass narrowed it to the integer path and named the measurement that
would decide it:

> *"the QEMU run, watching which addresses the rotation's quaternion loads actually resolve to
> against the ones the attitude update stores. That decides it without reconstructing the
> dataflow."*

and why static reading cannot get there:

> *"all 236 `r11` accesses are register-offset, none constant-offset. So 'the update writes one
> field, the rotation reads another' cannot be settled by comparing offsets — the addresses are
> computed at runtime."*

QEMU 11.1.1 accepts `-plugin` and ships none, so this is the instrument.

## Use

```sh
./build.sh                      # compiles against the INSTALLED qemu's header, then proves
                                # the plugin loads and observes accesses before reporting success
qemu-system-arm -machine mps2-an500 -cpu cortex-m7 -display none -serial none \
  -monitor stdio -kernel ../../../.scratch/invoke/ekf.elf \
  -plugin "$PWD/libmemtrace.dylib,out=/tmp/t.txt,lo=20000000,hi=20012000"
./analyse.py /tmp/t.txt --elf ../../../.scratch/invoke/ekf.elf --ticks 16 --marker-pc 00000462
./analyse.py --self-test
```

Output is one line per access: `<seq> <pc> <addr> <bytes> <R|W> <value>`. The sequence number is
what makes **order** recoverable, which is the whole question; the **value** is what makes the
quaternion identifiable by lookup against the parked state words instead of by inference from the
access pattern.

## What it found, and what it refuted

**The persistent quaternion is bit-identical between the two runtimes** — wasm offset `0xac18`,
at ticks 1, 2, 3, 15 and 16. That retires the *lagged / stale attitude* reading, which jess had
proposed from the tick-16 numbers and synth had adopted into the v0.80 plan. The attitude state
agrees; only what is computed from it diverges. See AFD-134.

Finding that led to a better instrument, which is where the sharp result is:
`tools/cascade-differential/linmem-capture.sh` dumps all 64 KiB of linear memory from both
runtimes and diffs it. At tick 16, six returned fields differ and **all six disagree in sign**,
over exactly the translational sub-vector, with the quaternion and the gyro passthrough bit-exact.

## The two things to know before trusting a result from this

**An empty answer is the dangerous one.** "No findings" and "the tracer was never wired up" are
the same empty file. So the trace carries a trailer with `seen` — accesses counted *before* any
filtering — and `analyse.py` refuses unless the trailer exists, `seen` is nonzero, and a
**potency control** is present: a store whose address and value are known in advance from the
image (the completion sentinel). A tracer that missed a store we know happened cannot be trusted
to have seen the ones under test.

**A flooding positive is just as useless as a vacuous zero.** The first predicate — find an
address loaded with a value another address has moved on from — returned 54,251 events over 1,662
address pairs, *including symmetric pairs*. Cause: wasm's shadow stack lives in linear memory, so
most of that traffic is frame slots recycling the same values every tick. That is "the predicate
is not specific", not 1,662 defects. Recorded in AFD-134 because the failure is reusable.

**And a stated blind spot:** value-identity only works for *distinctive* values. Measured, 15,193
of 15,295 stored values go to ≤ 8 addresses; the only ones above 16 are `deadbeef` (the harness's
paint, 1,792), `0` (987), `1.0` (62) and `-0.0` (56). So this cannot see a stale copy of the
**tick-1** quaternion, which is exactly the identity `(1, 0, 0, 0)`. Ticks 2..n are covered, and
the tool prints the exclusion rather than letting a reader assume full coverage.

## What it deliberately does not do

It does not say which pc is "the rotation" or "the attitude update". jess has no disassembly of
the fused module and will not guess a mapping and then present the guess as a measurement —
AFD-127 was exactly that, an inferred field layout reported as computed. The analyser reports
`(address, load pc, store pc, tick, value)`; naming the function is synth's half, and the pcs are
what make that a lookup for them rather than a re-derivation.
