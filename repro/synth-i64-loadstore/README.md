# synth arm backend: i64.load/i64.store unsupported (AFD-025 / synth#372)

Minimal repro: synth's arm (Cortex-M) backend cannot lower `i64.load`/`i64.store`
(same `_ => None` decoder path as the floats/memory.copy). Loud-skipped since
v0.11.46 (GI-FPU-001), but blocks falcon on-target (39 sites in the fused core).

```
synth compile i64-load-store.wat --target cortex-m7dp -o i64.elf
```

Expected: all four functions compile.
Observed (v0.11.46): ld64 (i64.load) + st64 (i64.store) loud-skipped;
ld32 (i32.load) and add64 (i64.add) compile — so the gap is i64 *memory*
load/store specifically; i64 arithmetic and i32 load both work.

Suggested fix: decode I64Load/I64Store to a lo/hi pair of i32 ldr/str
(offset + {0,4}), reusing the existing i64 register-pair regalloc (#171).
