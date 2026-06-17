# synth scalar-FP silent miscompile (AFD-024 / synth#369)

Minimal value-level repro for the synth arm-backend bug where scalar f32/f64
ops are silently dropped (decoder `map_operator` `_ => None`), so the function
returns a stale operand instead of the FP result.

```
synth compile fp-add-mul.wat --target cortex-m7dp -o fp.elf
arm-none-eabi-objdump -d fp.elf
```

Expected (correct): addf = a+b, mulf = a*b, run = 3.75 (i32 1081081856).
Observed (synth v0.11.45): addf/mulf emit `mov r0,r1; bx lr` (return operand b);
run emits a bare `bx lr` (constant fold dropped). wasmtime gives the correct value.

This is a CORRECTNESS hazard, not soft-float: there is no float math emitted at
all. Fix tracked upstream as GI-FPU-001 (loud Err) + GI-FPU-002 (VFP lowering).
