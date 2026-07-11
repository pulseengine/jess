# DD-018 TCB-link model — minimal demonstration + link oracle

Proves the **gale-maximal-wasm on-target linking model** (DD-018) on a minimal
example, **independent of the falcon #369/#275 poles**: the falcon on-target path
is `--relocatable + TCB-link` (native trusted base + fused wasm), NOT the
self-contained `--cortex-m` ELF. This shows that mechanism works end-to-end at
the link level.

## The pieces
- **`seam.wat`** — a minimal wasm: `compute() = tcb_seed() + 1`, importing the
  native primitive `env::tcb_seed` (stands in for a gale/WASI TCB primitive).
- **`tcb.S`** — a thin native TCB shim: provides `tcb_seed` (returns 0xCAFE) +
  a reset that calls `compute` and stores the result to DTCM.
- **`build.sh`** — the recipe + **link oracle**.

## The recipe (the ABI gust uses, DD-018)
```
synth compile seam.wasm -t cortex-m7dp --relocatable --native-pointer-abi --shadow-stack-size 1024
```
`--native-pointer-abi` makes the module **base-independent** (a host-pointer
drop-in, linmem base = 0), so no runtime R11/linear-memory setup is needed — the
image links against a thin native shim, not a full wasm runtime.

## Oracle (`build.sh`, exits non-zero on failure)
synth emits `compute` (defined) + **`tcb_seed` (undefined = the TCB seam)**; the
shim provides `tcb_seed`; they link into a complete ARM ELF with **0 undefined
symbols**. Negative-controlled: linking without the shim errors on the undefined
`tcb_seed` (the seam is real — synth genuinely emits it as a relocation the native
trusted base must satisfy).

```
SYNTH=/path/to/synth ./build.sh
→ LINK OK — DD-018 TCB seam fully resolved: wasm(compute) + native(tcb_seed) -> complete ARM image, 0 undefined.
```

## Rung 2 — EXECUTION oracle (`run-oracle.sh` + `boot.resc`, GREEN)
The linked image now **runs on emulated RT1176 Cortex-M7** and produces the
correct value: `compute() = tcb_seed()+1 = 0xCAFF` observed in DTCM @0x20010000.

```
RENODE=/path/to/renode ./run-oracle.sh
→ EXEC OK — DD-018 image runs on RT1176 Cortex-M7: wasm compute()=tcb_seed()+1=0xCAFF observed in DTCM.
```

- **Negative-controlled:** before execution the same DTCM word is `0x00000000`
  (Renode zeroes RAM), so `0xCAFF` can *only* come from `compute()` actually
  running — the value is produced on ARM, not preloaded.
- **The earlier "boot hang" was a misread, not a bug.** After `compute` stores
  its result, `_reset` idle-spins at `b .` (PC parks at 0x14). That stable PC was
  mistaken for a hang; reading the observation word shows the compute already ran.
  Note the disassembly: with `--native-pointer-abi` synth folds the shadow stack
  into the **native ARM `sp`** (`push {r4-r8,lr}; sub sp,#24; … ; pop`), so
  `compute` is self-contained — **no** `.data`/`.bss`/shadow-global init is needed
  (the previously-banked "needs cortex-m-rt startup" hypothesis was wrong).

This is the minimal analogue of `tools/bench/falcon-reloc-spike.sh` point 1
("falcon dissolves --relocatable to a valid ELF relocatable object; TCB-link
viable") — now carried one rung further, to actual on-target execution.

## Next rung (not yet green)
Promote `run-oracle.sh` to a `renode-test` `.robot` so the execution assertion can
join the CI `renode-smoke` gate (currently the local-oracle pattern, matching
`build.sh`). Then scale the seam from the toy `tcb_seed` to a real gale/WASI TCB
primitive.
