# Bulk-memory OOB-trap oracle (synth#374 / AFD-026 / REQ-PIX-001)

Hermetic Renode RT1176 verification of the ONE path synth's unicorn differential
can't see: a wasm bulk-memory OOB access → inline `UDF` → (UsageFault disabled →
escalates) HardFault → vector table → `Trap_Handler`. Confirms the self-contained
synth ELF's vector table actually routes the fault on real M7 silicon semantics.

ELFs are synth-compiled (`--target cortex-m7dp --safety-bounds software`) from
**synth main @39010ce** (= v0.11.49 content, the #376 bulk-mem lowering). Rebuild
from the v0.11.49 release tag once it ships:

```
synth compile oob.wasm -o oob.elf --target cortex-m7dp --safety-bounds software
synth compile ok.wasm  -o ok.elf  --target cortex-m7dp --safety-bounds software
```

- `oob.wat`: entry `run` does `memory.copy(0,0,200000)` — len > the 64 KiB page →
  end-exclusive OOB → must TRAP. Expected: PC ends in `Trap_Handler`.
- `ok.wat`:  entry `run` does `memory.fill(0,0xAB,16)` — in-bounds → must COMPLETE.
  Expected: PC ends at the `Reset_Handler` post-call spin, NOT `Trap_Handler`.

Static check (in the ELF): vector slot 3 (HardFault) and slot 6 (UsageFault) both
point to `Trap_Handler` (0x9F thumb), so escalation and direct routing both land
correctly. This robot confirms it dynamically. Driven by rt1176-bulkmem.robot.
